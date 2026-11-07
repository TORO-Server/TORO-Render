class_name WatchJob
extends RefCounted
## Resident updater for several maps in one process. Every cycle it asks each map's region directory which chunks the game
## server saved since the last cycle (AnvilChanges), turns them into mega tiles to re-render and works the queue off while
## the machine is quiet: the renderer stays set up between batches, tiles go through the usual hash skip, zoom-out parents
## are rebuilt right after.
##
## Order of work: mega tiles close to a player first (positions arrive over the WebSocket live feed), the rest in the order
## they were queued; anything waiting longer than --stale-after seconds goes ahead of everything else.
##
## Block-change events from the game server (DirtyFeed) merge into the same pending queue as the Anvil scan -- a mega
## tile that is already queued keeps its first queued time -- and flood control keeps a WorldEdit spree or a griefer
## placing blocks at full speed from starving the rest: a rendered mega waits out --mega-cooldown before it may be
## drawn again, a mega that keeps being re-offered while queued counts as hot (demoted, and only so many hot megas
## per batch), one seat of every batch is reserved for the oldest queued mega, and a map whose queue grows past
## --bbox-threshold is worked off in plain row order over its bounding box instead of by priority. Nothing is ever
## dropped for flooding: the worst case is a longer wait.
##
## A mega tile is counted as attempted (on disk) before drawing and the count is cleared afterwards, so a count that survives
## a restart means the process died on it. Those are retried one at a time and dropped after MAX_ATTEMPTS, so one bad chunk
## cannot keep the container in a crash loop. The tile is queued again the next time its chunks change.

const MAX_ATTEMPTS := 3
## A mega tile offered again at least this many times while queued counts as hot.
const HOT_HEAT := 3
## Rank penalty per heat: one heat pushes a mega about this many mega tiles away from the players.
const HEAT_DISTANCE := 2.0

class MapState:
	var def: MapDef
	var persp: Persp
	var changes := AnvilChanges.new()
	var since := 0.0
	## Vector2i -> unix time it was queued
	var pending := {}
	## Vector2i -> times the process started drawing it without finishing
	var attempts := {}
	## Vector2i -> unix time before which the mega tile may not be drawn again (flood control)
	var cooldown_until := {}
	## Vector2i -> how often the mega tile was offered again while it was already queued (flood control)
	var heat := {}
	var path := ""

var maps: Array[MapState] = []
var pool: RendererPool
var store: TileStore
var gate: Gate
var feed: LiveFeed
## Block-change events from the game server; null when the feed is off.
var dirty_feed: DirtyFeed
var interval := 60.0
var overlap := 30.0
var max_megas := 4
var stale_after := 600.0
## Seconds a rendered mega tile waits before events may have it drawn again (0 disables the cooldown).
var mega_cooldown := 240.0
## A map with at least this many pending mega tiles is worked off in row order (0 disables).
var bbox_threshold := 256
## true: one scan and at most one batch, then return (tests)
var once := false
var _zoom: ZoomBuilder


func add(def: MapDef, state_dir: String) -> bool:
	var ms := MapState.new()
	ms.def = def
	ms.persp = def.persp()
	if ms.persp == null:
		push_error("map %d: unknown perspective %s" % [def.id, def.persp_name])
		return false
	ms.path = state_dir.path_join("watch-%d.json" % def.id)
	ms.since = Time.get_unix_time_from_system()  # first start: only what changes from now on
	var f := FileAccess.open(ms.path, FileAccess.READ)
	if f != null:
		var st = JSON.parse_string(f.get_as_text())
		if st is Dictionary:
			ms.since = float(st.get("since", ms.since))
			for e in st.get("pending", []):
				var m := Vector2i(int(e[0]), int(e[1]))
				ms.pending[m] = float(e[2]) if e.size() > 2 else Time.get_unix_time_from_system()
				if e.size() > 3 and int(e[3]) > 0:
					ms.attempts[m] = int(e[3])
			for e in st.get("cooldown", []):
				ms.cooldown_until[Vector2i(int(e[0]), int(e[1]))] = float(e[2])
			for e in st.get("heat", []):
				ms.heat[Vector2i(int(e[0]), int(e[1]))] = int(e[2])
	maps.append(ms)
	return true


func _save(ms: MapState) -> void:
	DirAccess.make_dir_recursive_absolute(ms.path.get_base_dir())
	var pend := []
	for m: Vector2i in ms.pending:
		pend.append([m.x, m.y, ms.pending[m], ms.attempts.get(m, 0)])
	var cool := []
	for m: Vector2i in ms.cooldown_until:
		cool.append([m.x, m.y, ms.cooldown_until[m]])
	var heat := []
	for m: Vector2i in ms.heat:
		if int(ms.heat[m]) > 0:
			heat.append([m.x, m.y, ms.heat[m]])
	var f := FileAccess.open(ms.path, FileAccess.WRITE)
	if f == null:
		push_warning("cannot write %s" % ms.path)
		return
	f.store_string(JSON.stringify({"since": ms.since, "pending": pend, "cooldown": cool, "heat": heat}))


## Forgets the mega tiles that already took the process down MAX_ATTEMPTS times.
func _drop_failing(ms: MapState) -> void:
	for m: Vector2i in ms.attempts.keys():
		if ms.attempts[m] >= MAX_ATTEMPTS:
			Term.say("map %d: giving up on mega tile %s after %d attempts" % [ms.def.id, m, ms.attempts[m]])
			ms.pending.erase(m)
			ms.attempts.erase(m)


## True when the mega tile may be drawn now: not in its re-render cooldown, or already waiting so long that
## the cooldown no longer applies (an old tile is never held back forever).
func _eligible(ms: MapState, m: Vector2i, now: float) -> bool:
	if now - float(ms.pending[m]) > stale_after:
		return true
	return float(ms.cooldown_until.get(m, 0.0)) <= now


func _is_hot(ms: MapState, m: Vector2i) -> bool:
	return int(ms.heat.get(m, 0)) >= HOT_HEAT


## How many seats of one batch hot mega tiles may take: half of it, at least one, so a quiet map still drains.
func _hot_seats() -> int:
	return maxi(1, max_megas / 2)


## The next batch from the queue. `order` is the pending mega tiles in priority order; mega tiles in their
## cooldown are skipped. A tile the process died on goes alone, to tell which one is the cause. Otherwise one
## seat is reserved for the oldest queued tile, and hot tiles are capped to _hot_seats() seats, so a spot that
## keeps changing cannot fill every batch while the rest of the map waits.
func _next_group(ms: MapState, order: Array, now := -1.0) -> Array[Vector2i]:
	if now < 0.0:
		now = Time.get_unix_time_from_system()
	var ready: Array = []
	for m in order:
		if _eligible(ms, m, now):
			ready.append(m)
	var group: Array[Vector2i] = []
	if ready.is_empty():
		return group
	for m in ready:
		if ms.attempts.has(m):
			group.assign([m])
			return group
	var oldest: Vector2i = ready[0]
	for m in ready:
		if float(ms.pending[m]) < float(ms.pending[oldest]):
			oldest = m
	group.append(oldest)
	var hot_used := 1 if _is_hot(ms, oldest) else 0
	var deferred: Array = []
	for m in ready:
		if group.size() >= max_megas:
			break
		if m == oldest:
			continue
		if _is_hot(ms, m):
			if hot_used >= _hot_seats():
				deferred.append(m)
				continue
			hot_used += 1
		group.append(m)
	for m in deferred:
		if group.size() >= max_megas:
			break
		group.append(m)
	return group


## The next batch in plain row order (north to south, then west to east) over everything queued, for a map
## whose queue outgrew priority sorting. Cooldowns and the alone-rule for failed tiles still apply; the tiles
## are not reordered by players or heat, so a batch covers one compact area.
func _next_group_bbox(ms: MapState, now: float) -> Array[Vector2i]:
	var keys: Array = ms.pending.keys()
	keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.y < b.y or (a.y == b.y and a.x < b.x))
	var group: Array[Vector2i] = []
	for m in keys:
		if group.size() >= max_megas:
			break
		if not _eligible(ms, m, now):
			continue
		if ms.attempts.has(m):
			group.assign([m])
			return group
		group.append(m)
	return group


## The pending bounding box as [min, max] mega tiles, for reporting the bbox mode.
func _pending_bbox(ms: MapState) -> Array:
	var lo: Vector2i = ms.pending.keys()[0]
	var hi := lo
	for m: Vector2i in ms.pending:
		lo = Vector2i(mini(lo.x, m.x), mini(lo.y, m.y))
		hi = Vector2i(maxi(hi.x, m.x), maxi(hi.y, m.y))
	return [lo, hi]


## Merges changed chunks into the pending queue. A mega tile that is already queued keeps the time it was
## first queued; when the chunks come from block-change events (count_heat), a mega tile that is offered again
## also gains heat, which the batch selection uses to demote it. Returns how many mega tiles were new.
func _offer(ms: MapState, chunks: Array[Vector2i], now: float, count_heat: bool) -> int:
	if chunks.is_empty():
		return 0
	var fresh := AnvilChanges.megas_of(chunks, ms.persp, ms.def.min_y, ms.def.max_y, ms.def.mega)
	var added := 0
	for m in fresh:
		if ms.pending.has(m):
			if count_heat:
				ms.heat[m] = int(ms.heat.get(m, 0)) + 1
		else:
			ms.pending[m] = now
			added += 1
	return added


func _scan(ms: MapState, now: float) -> void:
	var chunks := ms.changes.changed_since(ms.def.region_dir, ms.since)
	if not chunks.is_empty():
		_offer(ms, chunks, now, false)
		Term.say("map %d: %d changed chunks -> %d pending" % [ms.def.id, chunks.size(), ms.pending.size()])
	# the next look starts a little earlier so nothing saved while this one was reading is missed
	ms.since = now - overlap


## Merges the block-change events the feed collected into the queues of their maps.
func _drain_dirty(now: float) -> void:
	if dirty_feed == null:
		return
	var events: Dictionary = dirty_feed.drain()
	for world: String in events:
		var matched := false
		for ms in maps:
			if ms.def.world == world:
				matched = true
				var added := _offer(ms, events[world], now, true)
				if added > 0:
					Term.say("map %d: events queued %d new mega tiles (%d pending)" % [ms.def.id, added, ms.pending.size()])
				_save(ms)
		if not matched:
			Term.say("dirty events for unknown world '%s' dropped" % world)


## smaller = sooner
func _rank(ms: MapState, m: Vector2i, queued: float, now: float) -> float:
	if now - queued > stale_after:
		return -1e12 + queued
	var best := 1e9
	if feed != null:
		var side := float(Planner.TILE * ms.def.mega)
		for p in feed.players(ms.def.world):
			var mp := ms.persp.world_to_map(float(p["x"]), float(p["y"]), float(p["z"]))
			best = minf(best, Vector2(m.x + 0.5 - mp[0] / side, m.y + 0.5 - mp[1] / side).length())
	# a mega tile that keeps changing counts as farther away, so the rest of the map goes first
	return best + queued * 1e-10 + float(int(ms.heat.get(m, 0))) * HEAT_DISTANCE


## Coroutine: `await watch.run()`.
func run() -> int:
	Term.say("watching %d maps, cycle %.0f s" % [maps.size(), interval])
	while true:
		var cycle := Time.get_unix_time_from_system()
		_drain_dirty(cycle)
		for ms in maps:
			_scan(ms, cycle)
			_save(ms)
		var rendered := false
		var why := gate.reason()
		if why == "":
			rendered = _work_one_group()
		elif _pending_total() > 0:
			Term.say("postponing %d mega tiles: %s" % [_pending_total(), why])
		if once:  # one look, at most one batch
			return 0
		if not rendered:
			await Term.sleep(maxf(1.0, interval - (Time.get_unix_time_from_system() - cycle)))
		else:
			await Term.sleep(0.5)  # lets the main loop breathe between batches
	return 0


func _pending_total() -> int:
	var n := 0
	for ms in maps:
		n += ms.pending.size()
	return n


## Renders and uploads the most urgent batch of one map; true when something was done.
func _work_one_group() -> bool:
	var now := Time.get_unix_time_from_system()
	var best_ms: MapState = null
	var best_rank := INF
	for ms in maps:
		_drop_failing(ms)
		for m: Vector2i in ms.pending:
			if not _eligible(ms, m, now):
				continue
			var r := _rank(ms, m, ms.pending[m], now)
			if r < best_rank:
				best_rank = r
				best_ms = ms
	if best_ms == null:
		return false
	var ms := best_ms
	var group: Array[Vector2i]
	if bbox_threshold > 0 and ms.pending.size() >= bbox_threshold:
		group = _next_group_bbox(ms, now)
		var bb := _pending_bbox(ms)
		Term.say("map %d: %d pending over the limit %d, working the bbox %s..%s in row order" % [ms.def.id, ms.pending.size(), bbox_threshold, bb[0], bb[1]])
	else:
		var order: Array = ms.pending.keys()
		order.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return _rank(ms, a, ms.pending[a], now) < _rank(ms, b, ms.pending[b], now))
		group = _next_group(ms, order, now)
	if group.is_empty():
		return false
	if not store.ensure_connected():
		Term.say("database unreachable: " + store.error)
		return false
	store.map_id = ms.def.id
	var iso := pool.renderer(ms.def.persp_name, ms.def.region_dir)
	if iso == null:
		return false
	for m in group:
		ms.attempts[m] = ms.attempts.get(m, 0) + 1
	_save(ms)
	var t0 := Time.get_ticks_msec()
	var tiles := pool.render_megas(iso, group, ms.def.mega, ms.def.min_y, ms.def.max_y)
	var t1 := Time.get_ticks_msec()
	var res := Publisher.new(store).upload(tiles, int(Time.get_unix_time_from_system() * 1000.0))
	var keys := {}
	for c in res["changed"]:
		keys[c] = true
	if _zoom == null:
		_zoom = ZoomBuilder.new(store, pool.rd)
	_zoom.rebuild(keys, res["changed"], ms.def.zoom_max, false, int(Time.get_unix_time_from_system() * 1000.0))
	# the process survived the batch, so the count does not apply any more (database errors are retried without a limit)
	for m in group:
		ms.attempts.erase(m)
	if store.error != "":
		Term.say("map %d: upload failed (%s), will retry" % [ms.def.id, store.error])
		store.error = ""
		_save(ms)
		return false
	var done_at := Time.get_unix_time_from_system()
	for m in group:
		ms.pending.erase(m)
		ms.heat.erase(m)
		if mega_cooldown > 0.0:
			ms.cooldown_until[m] = done_at + mega_cooldown
	_save(ms)
	Term.say("map %d: megas %s (%d) render %.1fs upload %.1fs | %s" % [ms.def.id, group[0], group.size(), (t1 - t0) / 1000.0, (Time.get_ticks_msec() - t1) / 1000.0, res["text"]])
	return true
