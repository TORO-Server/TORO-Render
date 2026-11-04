class_name RunJob
extends RefCounted
## Whole-map job: scan the world once, plan the candidate tiles and mega tiles, then for every group of
## mega tiles wait until the server is quiet, render, upload zoom 0 and go on. The zoom-out levels are rebuilt once at the
## end from the tiles that changed. Progress lives in the state directory, so the job can be stopped and resumed any time.

var map: MapDef
var pool: RendererPool
var store: TileStore
var gate: Gate
var args: Args


func _init(args_: Args, map_: MapDef, pool_: RendererPool, store_: TileStore, gate_: Gate) -> void:
	args = args_
	map = map_
	pool = pool_
	store = store_
	gate = gate_


func _fail(msg: String) -> int:
	Term.say(msg + (" (" + store.error + ")" if store.error != "" else ""))
	return 1


## Coroutine: `await job.run()`. Returns the process exit code.
func run() -> int:
	var state_dir := args.text("state-dir", "/state")
	var persp := map.persp()
	if persp == null:
		return _fail("unknown perspective %s" % map.persp_name)

	# 1. scan (cached)
	var cache_path := args.text("scan-cache", state_dir.path_join("scan-%d.bin" % map.id))
	var scan: ScanCache = null if args.flag("rescan") else ScanCache.load_file(cache_path)
	if scan == null:
		Term.say("scanning %s" % map.region_dir)
		var t0 := Time.get_ticks_msec()
		scan = ScanCache.build(map.region_dir)
		if not scan.save(cache_path):
			return _fail("cannot write scan cache %s" % cache_path)
		Term.say("scan: %d non-empty chunks, %.1f s" % [scan.count(), (Time.get_ticks_msec() - t0) / 1000.0])
	if scan.count() == 0:
		return _fail("nothing to render in %s" % map.region_dir)

	# 2. plan
	var keys := Planner.tile_keys(scan, persp)
	var planned := Planner.megas_of(keys, map.mega, args.ints("bbox"))
	keys = planned["keys"]
	var megas: Array[Vector2i] = planned["megas"]
	var lo := scan.min_y()
	var hi := scan.max_y()
	Term.say("%d candidate tiles, y range %d..%d, %d mega-tiles of %dx%d" % [keys.size(), lo, hi, megas.size(), map.mega, map.mega])
	var only_missing := args.flag("only-missing")
	if only_missing or args.flag("count-missing"):
		var miss := Planner.missing_megas(store, keys, megas, map.mega, Term.say)
		Term.say("missing: %d tiles in %d of %d mega-tiles" % [miss["missing"], miss["megas"].size(), megas.size()])
		if store.error != "":
			return _fail("database error")
		if args.flag("count-missing"):
			return 0
		megas = miss["megas"]
	megas = megas.slice(args.integer("skip-megas"))

	# 3. render and upload, group by group
	var state_path := args.text("state", state_dir.path_join("run-%d.json" % map.id))
	var done := _load_done(state_path)
	var todo: Array[Vector2i] = []
	for m in megas:
		if not done.has("%d,%d" % [m.x, m.y]):
			todo.append(m)
	Term.say("%d mega tiles to do, state %s" % [todo.size(), state_path])
	var iso := pool.renderer(map.persp_name, map.region_dir)
	if iso == null:
		return _fail("renderer setup failed")
	var pub := Publisher.new(store)
	pub.candidates = keys
	pub.only_missing = only_missing
	var changed_path := state_dir.path_join("changed-%d.txt" % map.id)
	var per_run := args.integer("per-run", 8)
	var limit := args.integer("limit")
	var gap := args.number("gap", 1.0)
	var n_done := 0
	for g in range(0, todo.size(), per_run):
		var group := todo.slice(g, g + per_run)
		await gate.wait_quiet()
		if not store.ensure_connected():
			return _fail("database unreachable")
		var t0 := Time.get_ticks_msec()
		var tiles := pool.render_megas(iso, group, map.mega, lo, hi)
		var t1 := Time.get_ticks_msec()
		var res := pub.upload(tiles, int(Time.get_unix_time_from_system() * 1000.0))
		if store.error != "":
			return _fail("upload failed")
		_record(changed_path, res["changed"])
		_keep_png(args.text("keep-png"), tiles)
		for m in group:
			done["%d,%d" % [m.x, m.y]] = true
		_save_done(state_path, done)
		n_done += group.size()
		Term.say("megas %s..%s [%d/%d] render %.1fs upload %.1fs | %s" % [group[0], group[-1], n_done, todo.size(), (t1 - t0) / 1000.0, (Time.get_ticks_msec() - t1) / 1000.0, res["text"]])
		if limit > 0 and n_done >= limit:
			break
		await Term.sleep(gap)

	# 4. zoom-out levels, once, from every tile recorded as changed (also by earlier interrupted runs)
	var seeds := _load_seeds(changed_path)
	var zoom_all := args.flag("zoom-all")
	var since := args.integer("zoom-since")
	if (not seeds.is_empty() or zoom_all or since > 0) and not store.dry_run:
		await gate.wait_quiet()
		if since > 0:
			var cand: Array[Vector2i] = []
			for k in keys:
				cand.append(Vector2i(Planner.key_a(k), Planner.key_b(k)))
			for c in store.updated_since(0, cand, since):
				seeds[c] = true
			Term.say("zoom-since: %d tiles written since the cutoff" % seeds.size())
		Term.say("rebuilding zoom-out levels")
		var zoom := ZoomBuilder.new(store, pool.rd)
		zoom.rebuild(seeds, {}, map.zoom_max, zoom_all, int(Time.get_unix_time_from_system() * 1000.0))
		if store.error != "":
			return _fail("zoom failed")
		if FileAccess.file_exists(changed_path):
			DirAccess.rename_absolute(changed_path, changed_path + ".done")
	Term.say("finished" if limit == 0 else "stopped at limit")
	return 0


static func _load_done(path: String) -> Dictionary:
	var done := {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f != null:
		var arr = JSON.parse_string(f.get_as_text())
		if arr is Array:
			for s in arr:
				done[str(s)] = true
	return done


static func _save_done(path: String, done: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(done.keys()))


## appends the changed zoom-0 tiles ("x y" per line) - the seed of the final zoom pass
static func _record(path: String, changed: Dictionary) -> void:
	if changed.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.READ_WRITE) if FileAccess.file_exists(path) else FileAccess.open(path, FileAccess.WRITE)
	f.seek_end()
	for c: Vector2i in changed:
		f.store_line("%d %d" % [c.x, c.y])


static func _load_seeds(path: String) -> Dictionary:
	var seeds := {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f != null:
		while not f.eof_reached():
			var p := f.get_line().split(" ", false)
			if p.size() == 2:
				seeds[Vector2i(int(p[0]), int(p[1]))] = true
	return seeds


static func _keep_png(dir: String, tiles: Dictionary) -> void:
	if dir == "":
		return
	DirAccess.make_dir_recursive_absolute(dir)
	for xy: Vector2i in tiles:
		if tiles[xy] != null:
			var img: Image = tiles[xy]["img"]
			img.save_png(dir.path_join("%d_%d.png" % [xy.x, xy.y]))
			var f := FileAccess.open(dir.path_join("%d_%d.webp" % [xy.x, xy.y]), FileAccess.WRITE)
			f.store_buffer(TileCodec.encode_webp(img))
