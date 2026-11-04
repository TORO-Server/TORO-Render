class_name WatchJob
extends RefCounted
## Resident updater for several maps in one process. Every cycle it asks each map's region directory which chunks the game
## server saved since the last cycle (AnvilChanges), turns them into mega tiles to re-render and works the queue off while
## the machine is quiet: the renderer stays set up between batches, tiles go through the usual hash skip, zoom-out parents
## are rebuilt right after.
##
## Order of work: mega tiles close to a player first (positions arrive over the WebSocket live feed), the rest in the order
## they were queued; anything waiting longer than --stale-after seconds goes ahead of everything else.

class MapState:
	var def: MapDef
	var persp: Persp
	var changes := AnvilChanges.new()
	var since := 0.0
	## Vector2i -> unix time it was queued
	var pending := {}
	var path := ""

var maps: Array[MapState] = []
var pool: RendererPool
var store: TileStore
var gate: Gate
var feed: LiveFeed
var interval := 60.0
var overlap := 30.0
var max_megas := 4
var stale_after := 600.0
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
				ms.pending[Vector2i(int(e[0]), int(e[1]))] = float(e[2]) if e.size() > 2 else Time.get_unix_time_from_system()
	maps.append(ms)
	return true


func _save(ms: MapState) -> void:
	DirAccess.make_dir_recursive_absolute(ms.path.get_base_dir())
	var pend := []
	for m: Vector2i in ms.pending:
		pend.append([m.x, m.y, ms.pending[m]])
	var f := FileAccess.open(ms.path, FileAccess.WRITE)
	f.store_string(JSON.stringify({"since": ms.since, "pending": pend}))


func _scan(ms: MapState, now: float) -> void:
	var chunks := ms.changes.changed_since(ms.def.region_dir, ms.since)
	if not chunks.is_empty():
		var fresh := AnvilChanges.megas_of(chunks, ms.persp, ms.def.min_y, ms.def.max_y, ms.def.mega)
		for m in fresh:
			if not ms.pending.has(m):
				ms.pending[m] = now
		Term.say("map %d: %d changed chunks -> %d mega tiles (%d pending)" % [ms.def.id, chunks.size(), fresh.size(), ms.pending.size()])
	# the next look starts a little earlier so nothing saved while this one was reading is missed
	ms.since = now - overlap


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
	return best + queued * 1e-10


## Coroutine: `await watch.run()`.
func run() -> int:
	Term.say("watching %d maps, cycle %.0f s" % [maps.size(), interval])
	while true:
		var cycle := Time.get_unix_time_from_system()
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
		for m: Vector2i in ms.pending:
			var r := _rank(ms, m, ms.pending[m], now)
			if r < best_rank:
				best_rank = r
				best_ms = ms
	if best_ms == null:
		return false
	var ms := best_ms
	var order: Array = ms.pending.keys()
	order.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return _rank(ms, a, ms.pending[a], now) < _rank(ms, b, ms.pending[b], now))
	var group: Array[Vector2i] = []
	group.assign(order.slice(0, max_megas))
	if not store.ensure_connected():
		Term.say("database unreachable: " + store.error)
		return false
	store.map_id = ms.def.id
	var iso := pool.renderer(ms.def.persp_name, ms.def.region_dir)
	if iso == null:
		return false
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
	if store.error != "":
		Term.say("map %d: upload failed (%s), will retry" % [ms.def.id, store.error])
		store.error = ""
		return false
	for m in group:
		ms.pending.erase(m)
	_save(ms)
	Term.say("map %d: megas %s (%d) render %.1fs upload %.1fs | %s" % [ms.def.id, group[0], group.size(), (t1 - t0) / 1000.0, (Time.get_ticks_msec() - t1) / 1000.0, res["text"]])
	return true
