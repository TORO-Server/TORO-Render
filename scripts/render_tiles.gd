extends SceneTree
## CLI entry. Run with a display driver (not --headless), arguments after `--`:
##   --region-dir DIR      world region directory (r.X.Z.mca)
##   --tiles tx,ty,w,h     tile rectangle(s) at zoom 0, several separated by ';' (default 0,0,1,1)
##   --out DIR             write {x}_{y}.png / .webp and manifest.json here; with several rectangles each one
##                         goes to DIR/r{tx}_{ty}/
##   --data-dir DIR        output of tools/build_data.py (default res://data)
##   --repeat N            render the (first) rectangle N times (timing only)
##   --ref DIR             compare against reference PNGs ({x}_{y}.png) and print the pixel match
##   --columns cpu|gpu     column builder (default gpu), --verify 1 cross-checks both

var _hash_ms := 0.0
var _webp_ms := 0.0


func _initialize() -> void:
	var args := _parse(OS.get_cmdline_user_args())
	var region_dir: String = args.get("region-dir", "")
	if region_dir == "":
		push_error("--region-dir required")
		quit(2)
		return
	var rects: Array[PackedInt32Array] = []
	for part in String(args.get("tiles", "0,0,1,1")).split(";", false):
		rects.append(PackedInt32Array(Array(part.split(",")).map(func(s): return int(s))))
	var out_dir: String = args.get("out", "")
	var data_dir: String = args.get("data-dir", ProjectSettings.globalize_path("res://data"))
	var repeat := int(args.get("repeat", "1"))
	var ref_dir: String = args.get("ref", "")
	var cpu_columns: bool = args.get("columns", "gpu") == "cpu"
	var verify: bool = args.get("verify", "0") == "1"

	var t_start := Time.get_ticks_usec()
	print("script start at %d ms after engine start" % Time.get_ticks_msec())
	var table := BlockTable.new()
	if not table.load_dir(data_dir):
		quit(1)
		return
	var world := WorldReader.new(region_dir, table)
	var mode: String = args.get("mode", "mesh")
	var renderer: FlatRenderer = null
	var iso: IsoRenderer = null
	if mode == "fast":
		renderer = FlatRenderer.new()
		if not renderer.setup(table, world):
			quit(1)
			return
		renderer.gpu_columns = not cpu_columns
		renderer.verify = verify
		print("device: %s  driver: %s  setup %.0f ms" % [renderer.device_name, RenderingServer.get_current_rendering_driver_name(), (Time.get_ticks_usec() - t_start) / 1000.0])
	else:
		var persp := Persp.by_name(args.get("persp", "iso_S_90_lowres"))
		if persp == null:
			push_error("unknown perspective %s" % args.get("persp", ""))
			quit(2)
			return
		var reg := StateRegistry.new()
		if not reg.load_dir(data_dir):
			quit(1)
			return
		iso = IsoRenderer.new()
		iso.min_y = int(args.get("min-y", "-64"))
		iso.max_y = int(args.get("max-y", "320"))
		iso.front_ccw_vk = args.get("flip-front", "0") == "1"
		iso.verbose = args.get("verbose", "0") == "1"
		iso.gpu_mesh = args.get("mesher", "gpu") != "cpu"
		if args.has("probe"):
			iso.probe = PackedInt32Array(Array(String(args["probe"]).split(",")).map(func(s): return int(s)))
		if not iso.setup(persp, reg, table, world):
			quit(1)
			return
		print("device: %s  driver: %s  persp: %s  setup %.0f ms" % [iso.device_name, RenderingServer.get_current_rendering_driver_name(), persp.name, (Time.get_ticks_usec() - t_start) / 1000.0])
		if args.has("cmp-chunk"):
			for part in String(args["cmp-chunk"]).split(";"):
				var cc := part.split(",")
				iso.compare_meshers(int(cc[0]), int(cc[1]))
			quit(0)
			return

	var total_tiles := 0
	var matched := 0
	var compared := 0
	for rect in rects:
		var tiles: Array[Image] = []
		for i in (repeat if rects.size() == 1 else 1):
			var t0 := Time.get_ticks_usec()
			if iso != null:
				iso.next_generation()
				tiles = iso.render(rect[0], rect[1], rect[2], rect[3])
			else:
				tiles = renderer.render(rect[0], rect[1], rect[2], rect[3])
			print("render rect %s: %.0f ms (%d tiles)" % [rect, (Time.get_ticks_usec() - t0) / 1000.0, tiles.size()])
		var dir := out_dir
		if out_dir != "" and rects.size() > 1:
			dir = out_dir.path_join("r%d_%d" % [rect[0], rect[1]])
		var r := _emit(tiles, rect, dir, ref_dir)
		total_tiles += tiles.size()
		matched += r[0]
		compared += r[1]
	if iso != null:
		print("mesh(cpu) %.0f ms  gather %.0f ms  gpu(raster+readback) %.0f ms  quads %d  chunks decoded %d (%.0f ms)" % [iso.timing["mesh_ms"], iso.timing["gather_ms"], iso.timing["gpu_ms"], iso.timing["quads"], world.stats["chunks"], world.stats["chunk_ms"]])
		if iso.gpu_mesh:
			print("gpu mesher: pack %.0f ms, mesh %.0f ms" % [iso.gmesher.timing["pack_ms"], iso.gmesher.timing["mesh_ms"]])
		if not iso.reg.unknown.is_empty():
			var uk := iso.reg.unknown.keys()
			print("unknown blockstates: ", uk.slice(0, 10))
	else:
		print("cpu(columns) %.0f ms  gpu(dispatch+readback) %.0f ms  chunks decoded %d (%.0f ms)" % [renderer.cpu_ms, renderer.gpu_ms, world.stats["chunks"], world.stats["chunk_ms"]])
	print("hash %.0f ms, webp %.0f ms, %d tiles" % [_hash_ms, _webp_ms, total_tiles])
	if verify and renderer != null:
		print("verify: %d columns differ between GPU and CPU column builders" % renderer.mismatched_columns)
	if not table.unknown.is_empty():
		var keys := table.unknown.keys()
		keys.sort_custom(func(a, b): return table.unknown[a] > table.unknown[b])
		print("unknown blocks: ", keys.slice(0, 10))
	if compared > 0:
		print("pixel match vs reference: %d/%d = %.2f%%" % [matched, compared, 100.0 * matched / compared])
	quit(0)


## Writes the tiles of one rectangle; returns [matching pixels, compared pixels] against --ref.
func _emit(tiles: Array[Image], rect: PackedInt32Array, out_dir: String, ref_dir: String) -> Array:
	var manifest := []
	var matched := 0
	var total := 0
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
			_hash_ms += (Time.get_ticks_usec() - t_h) / 1000.0
			var entry := {"x": x, "y": y, "blank": blank, "hash": hash}
			if not blank and out_dir != "":
				DirAccess.make_dir_recursive_absolute(out_dir)
				img.save_png(out_dir.path_join("%d_%d.png" % [x, y]))
				var t_w := Time.get_ticks_usec()
				var webp := TileCodec.encode_webp(img)
				_webp_ms += (Time.get_ticks_usec() - t_w) / 1000.0
				var f := FileAccess.open(out_dir.path_join("%d_%d.webp" % [x, y]), FileAccess.WRITE)
				f.store_buffer(webp)
				entry["webp_bytes"] = webp.size()
			if ref_dir != "":
				var rp := ref_dir.path_join("%d_%d.png" % [x, y])
				if FileAccess.file_exists(rp):
					var ref := Image.load_from_file(rp)
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
					matched += same
					total += drawn
					entry["match"] = "%d/%d" % [same, drawn]
			manifest.append(entry)
	# an out dir with only blank tiles still gets a manifest so callers can tell the rectangle was processed
	if out_dir != "":
		DirAccess.make_dir_recursive_absolute(out_dir)
		var mf := FileAccess.open(out_dir.path_join("manifest.json"), FileAccess.WRITE)
		mf.store_string(JSON.stringify(manifest))
	return [matched, total]


func _parse(argv: PackedStringArray) -> Dictionary:
	var d := {}
	var i := 0
	while i < argv.size():
		var a := argv[i]
		if a.begins_with("--") and i + 1 < argv.size():
			d[a.substr(2)] = argv[i + 1]
			i += 2
		else:
			i += 1
	return d
