extends SceneTree
## CLI entry. Run with a display driver (not --headless), arguments after `--`:
##   --region-dir DIR   world region directory (r.X.Z.mca)
##   --tiles tx,ty,w,h  tile rectangle at zoom 0 (default 0,0,1,1)
##   --out DIR          write {x}_{y}.png / .webp and manifest.json here
##   --data-dir DIR     output of tools/build_data.py (default res://data)
##   --repeat N         render the rectangle N times (timing only)
##   --ref DIR          compare against reference PNGs ({x}_{y}.png) and print the pixel match

func _initialize() -> void:
	var args := _parse(OS.get_cmdline_user_args())
	var region_dir: String = args.get("region-dir", "")
	if region_dir == "":
		push_error("--region-dir required")
		quit(2)
		return
	var rect := PackedInt32Array([0, 0, 1, 1])
	if args.has("tiles"):
		rect = PackedInt32Array(Array(String(args["tiles"]).split(",")).map(func(s): return int(s)))
	var out_dir: String = args.get("out", "")
	var data_dir: String = args.get("data-dir", ProjectSettings.globalize_path("res://data"))
	var repeat := int(args.get("repeat", "1"))
	var ref_dir: String = args.get("ref", "")

	var t_start := Time.get_ticks_usec()
	var table := BlockTable.new()
	if not table.load_dir(data_dir):
		quit(1)
		return
	var world := WorldReader.new(region_dir, table)
	var renderer := FlatRenderer.new()
	if not renderer.setup(table, world):
		quit(1)
		return
	print("device: %s  driver: %s  setup %.0f ms" % [renderer.device_name, RenderingServer.get_current_rendering_driver_name(), (Time.get_ticks_usec() - t_start) / 1000.0])

	var tiles: Array[Image] = []
	for i in repeat:
		var t0 := Time.get_ticks_usec()
		tiles = renderer.render(rect[0], rect[1], rect[2], rect[3])
		print("render %d: %.0f ms (%d tiles)" % [i, (Time.get_ticks_usec() - t0) / 1000.0, tiles.size()])
	print("cpu(columns) %.0f ms  gpu(dispatch+readback) %.0f ms  chunks decoded %d (%.0f ms)" % [renderer.cpu_ms, renderer.gpu_ms, world.stats["chunks"], world.stats["chunk_ms"]])
	if not table.unknown.is_empty():
		var keys := table.unknown.keys()
		keys.sort_custom(func(a, b): return table.unknown[a] > table.unknown[b])
		print("unknown blocks: ", keys.slice(0, 10))

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
			var blank := TileCodec.is_blank(data)
			var hash := 0 if blank else TileCodec.crc_hash(data)
			var entry := {"x": x, "y": y, "blank": blank, "hash": hash}
			if not blank and out_dir != "":
				DirAccess.make_dir_recursive_absolute(out_dir)
				img.save_png(out_dir.path_join("%d_%d.png" % [x, y]))
				var webp := TileCodec.encode_webp(img)
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
	if out_dir != "":
		var mf := FileAccess.open(out_dir.path_join("manifest.json"), FileAccess.WRITE)
		mf.store_string(JSON.stringify(manifest, "  "))
	for e in manifest:
		print(e)
	if total > 0:
		print("pixel match vs reference: %d/%d = %.2f%%" % [matched, total, 100.0 * matched / total])
	quit(0)


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
