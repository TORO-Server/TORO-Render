class_name RenderCmd
extends RefCounted
## `render --region-dir DIR --tiles tx,ty,w,h[;...] [--persp NAME] [--out DIR] [--ref DIR]`
## Renders tile rectangles at zoom 0 and writes {x}_{y}.png / .webp (lossless, the NewImage payload) and manifest.json
## (HashCode = CRC32 over the ARGB ints) to --out; with several rectangles each one goes to OUT/r{tx}_{ty}/.
## --ref DIR compares the pixels with reference PNGs ({x}_{y}.png) and prints the match.
## Debug: --mesher cpu, --cmp-chunk cx,cz[;...] (CPU vs GPU mesher), --verbose 1, --min-y/--max-y, --repeat N.


static func run(args: Args) -> int:
	var region_dir := args.text("region-dir")
	if region_dir == "":
		push_error("--region-dir required")
		return 2
	var rects: Array[PackedInt32Array] = []
	for part in args.text("tiles", "0,0,1,1").split(";", false):
		rects.append(PackedInt32Array(Array(part.split(",")).map(func(s): return int(s))))
	var t_start := Time.get_ticks_usec()
	var pool := RendererPool.create(args.text("data-dir", ProjectSettings.globalize_path("res://data")))
	if pool == null:
		return 1
	var persp_name := args.text("persp", "iso_S_90_lowres")
	var persp := Persp.by_name(persp_name)
	if persp == null:
		push_error("unknown perspective %s" % persp_name)
		return 2
	var world := WorldReader.new(region_dir, pool.table)
	var iso := IsoRenderer.new()
	iso.rd = pool.rd
	iso.min_y = args.integer("min-y", -64)
	iso.max_y = args.integer("max-y", 320)
	iso.front_ccw_vk = args.flag("flip-front")
	iso.verbose = args.flag("verbose")
	iso.gpu_mesh = args.text("mesher", "gpu") != "cpu"
	if args.has("probe"):
		iso.probe = args.ints("probe")
	if not iso.setup(persp, pool.reg, pool.table, world):
		return 1
	print("device: %s  driver: %s  persp: %s  setup %.0f ms" % [pool.device_name, RenderingServer.get_current_rendering_driver_name(), persp.name, (Time.get_ticks_usec() - t_start) / 1000.0])
	if args.has("cmp-chunk"):
		for part in args.text("cmp-chunk").split(";"):
			var cc := part.split(",")
			iso.compare_meshers(int(cc[0]), int(cc[1]))
		return 0

	var out_dir := args.text("out")
	var ref_dir := args.text("ref")
	var repeat := args.integer("repeat", 1)
	var stats := {"hash_ms": 0.0, "webp_ms": 0.0, "tiles": 0, "matched": 0, "compared": 0}
	for rect in rects:
		var tiles: Array[Image] = []
		for _i in (repeat if rects.size() == 1 else 1):
			var t0 := Time.get_ticks_usec()
			iso.next_generation()
			tiles = iso.render(rect[0], rect[1], rect[2], rect[3])
			print("render rect %s: %.0f ms (%d tiles)" % [rect, (Time.get_ticks_usec() - t0) / 1000.0, tiles.size()])
		if tiles.is_empty():
			push_error("rect %s was not drawn" % [rect])
			continue
		var dir := out_dir
		if out_dir != "" and rects.size() > 1:
			dir = out_dir.path_join("r%d_%d" % [rect[0], rect[1]])
		_emit(tiles, rect, dir, ref_dir, stats)
	print("mesh(cpu) %.0f ms  gather %.0f ms  gpu(raster+readback) %.0f ms  quads %d  chunks decoded %d (%.0f ms)" % [iso.timing["mesh_ms"], iso.timing["gather_ms"], iso.timing["gpu_ms"], iso.timing["quads"], world.stats["chunks"], world.stats["chunk_ms"]])
	if iso.gpu_mesh:
		print("gpu mesher: pack %.0f ms, mesh %.0f ms" % [iso.gmesher.timing["pack_ms"], iso.gmesher.timing["mesh_ms"]])
	if not pool.reg.unknown.is_empty():
		print("unknown blockstates: ", pool.reg.unknown.keys().slice(0, 10))
	print("hash %.0f ms, webp %.0f ms, %d tiles" % [stats["hash_ms"], stats["webp_ms"], stats["tiles"]])
	if stats["compared"] > 0:
		print("pixel match vs reference: %d/%d = %.2f%%" % [stats["matched"], stats["compared"], 100.0 * stats["matched"] / stats["compared"]])
	return 0


static func _emit(tiles: Array[Image], rect: PackedInt32Array, out_dir: String, ref_dir: String, stats: Dictionary) -> void:
	var manifest := []
	var i := 0
	for ty in rect[3]:
		for tx in rect[2]:
			var x: int = rect[0] + tx
			var y: int = rect[1] + ty
			var img := tiles[i]
			i += 1
			var data := img.get_data()
			var t_h := Time.get_ticks_usec()
			var blank := TileCodec.is_blank(data)
			var hash := 0 if blank else TileCodec.crc_hash(data)
			stats["hash_ms"] += (Time.get_ticks_usec() - t_h) / 1000.0
			var entry := {"x": x, "y": y, "blank": blank, "hash": hash}
			if not blank and out_dir != "":
				DirAccess.make_dir_recursive_absolute(out_dir)
				img.save_png(out_dir.path_join("%d_%d.png" % [x, y]))
				var t_w := Time.get_ticks_usec()
				var webp := TileCodec.encode_webp(img)
				stats["webp_ms"] += (Time.get_ticks_usec() - t_w) / 1000.0
				FileAccess.open(out_dir.path_join("%d_%d.webp" % [x, y]), FileAccess.WRITE).store_buffer(webp)
				entry["webp_bytes"] = webp.size()
			if ref_dir != "":
				var rp := ref_dir.path_join("%d_%d.png" % [x, y])
				if FileAccess.file_exists(rp):
					var m := _compare(data, rp)
					stats["matched"] += m[0]
					stats["compared"] += m[1]
					entry["match"] = "%d/%d" % m
			manifest.append(entry)
	stats["tiles"] += tiles.size()
	# an out dir with only blank tiles still gets a manifest so callers can tell the rectangle was processed
	if out_dir != "":
		DirAccess.make_dir_recursive_absolute(out_dir)
		FileAccess.open(out_dir.path_join("manifest.json"), FileAccess.WRITE).store_string(JSON.stringify(manifest))


## [matching pixels, drawn pixels] against a reference PNG; pixels transparent in both do not count
static func _compare(data: PackedByteArray, ref_path: String) -> Array:
	var ref := Image.load_from_file(ref_path)
	ref.convert(Image.FORMAT_RGBA8)
	var rd_ := ref.get_data()
	var same := 0
	var drawn := 0
	for p in range(0, data.size(), 4):
		if rd_[p + 3] == 0 and data[p + 3] == 0:
			continue
		drawn += 1
		if rd_[p] == data[p] and rd_[p + 1] == data[p + 1] and rd_[p + 2] == data[p + 2] and rd_[p + 3] == data[p + 3]:
			same += 1
	return [same, drawn]
