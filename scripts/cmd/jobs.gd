class_name JobCmds
extends RefCounted
## Entry points of the commands that talk to the database: run, watch, zoom (and scan, which only reads the world).
## All of them are coroutines: `await JobCmds.run(args)`.


## `scan --region-dir DIR --out FILE`
static func scan(args: Args) -> int:
	var dir := args.text("region-dir")
	var out := args.text("out")
	if dir == "" or out == "":
		push_error("scan needs --region-dir and --out")
		return 2
	var t0 := Time.get_ticks_msec()
	var s := ScanCache.build(dir)
	if not s.save(out):
		push_error("cannot write %s" % out)
		return 1
	Term.say("scan: %d non-empty chunks, y %d..%d, %.1f s" % [s.count(), s.min_y(), s.max_y(), (Time.get_ticks_msec() - t0) / 1000.0])
	return 0


## `run --map-id N [--region-dir D] [--persp P] [--zoom-max Z] [--bbox tx0,ty0,tx1,ty1] [--only-missing|--count-missing]
##      [--zoom-all] [--zoom-since MS] [--skip-megas N] [--limit N] [--per-run N] [--keep-png DIR] [--state-dir DIR]`
## Whole-map job, rendering only while the server is quiet (default: nobody online, load < 4).
static func run(args: Args) -> int:
	var ctx := Context.create(args, 4.0, 0)
	var map := MapDef.from_args(args, ctx.cfg)
	if map.id == 0 or map.region_dir == "":
		push_error("run needs --map-id and a region directory (--region-dir or a config entry)")
		return 2
	if not ctx.attach(map):
		return 1
	if ctx.gate.max_players >= 0 and ctx.gate.online_file == "" and ctx.feed == null:
		Term.say("warning: no player source (--live / --online-file): rendering regardless of players")
	var pool: RendererPool = null  # --count-missing only plans: no GPU needed
	if not args.flag("count-missing"):
		pool = RendererPool.create(args.text("data-dir", "/data"))
		if pool == null:
			return 1
		Term.say("device: %s  driver: %s" % [pool.device_name, RenderingServer.get_current_rendering_driver_name()])
	return await RunJob.new(args, map, pool, ctx.store, ctx.gate).run()


## `watch --config maps.json [--map-id N,...] [--interval S] [--max-megas N] [--max-load L] [--stale-after S] [--once]`
## Resident updater for every map of the config.
static func watch(args: Args) -> int:
	var ctx := Context.create(args, 2.5, -1)
	if ctx.cfg.get("maps", []).is_empty():
		push_error("watch needs a config with maps (--config)")
		return 2
	var wanted := args.ints("map-id")
	var pool := RendererPool.create(args.text("data-dir", "/data"))
	if pool == null:
		return 1
	Term.say("device: %s  driver: %s" % [pool.device_name, RenderingServer.get_current_rendering_driver_name()])
	var job := WatchJob.new()
	job.pool = pool
	job.store = ctx.store
	job.gate = ctx.gate
	job.feed = ctx.feed
	job.interval = args.number("interval", 60.0)
	job.overlap = args.number("overlap", 30.0)
	job.max_megas = args.integer("max-megas", 4)
	job.stale_after = args.number("stale-after-queue", 600.0)
	job.once = args.flag("once")
	var state_dir := args.text("state-dir", "/state")
	for e in ctx.cfg["maps"]:
		var map := MapDef.from_entry(e)
		if not wanted.is_empty() and not wanted.has(map.id):
			continue
		if not ctx.store.ensure_connected():
			Term.say("database unreachable: " + ctx.store.error)
			return 1
		ctx.store.map_id = map.id
		map.world = ctx.store.world_name()
		if ctx.feed != null:
			ctx.feed.watch(map.world)
		if not job.add(map, state_dir):
			return 2
		Term.say("map %d: %s, world '%s', %s" % [map.id, map.persp_name, map.world, map.region_dir])
	return await job.run()


## `zoom --map-id N --zoom-max Z (--all | --seed FILE)` rebuilds the zoom-out levels without rendering.
## FILE has one "x y" zoom-0 tile per line.
static func zoom(args: Args) -> int:
	var ctx := Context.create(args, 4.0, -1)
	var map := MapDef.from_args(args, ctx.cfg)
	if map.id == 0 or not (args.flag("all") or args.has("seed")):
		push_error("zoom needs --map-id and --all or --seed FILE")
		return 2
	if not ctx.attach(map):
		return 1
	var seeds := RunJob._load_seeds(args.text("seed")) if args.has("seed") else {}
	var rd := RenderingServer.create_local_rendering_device()
	var zb := ZoomBuilder.new(ctx.store, rd)
	zb.rebuild(seeds, {}, map.zoom_max, args.flag("all"), int(Time.get_unix_time_from_system() * 1000.0))
	return 1 if ctx.store.error != "" else 0
