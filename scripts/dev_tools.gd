extends SceneTree
## Debugging helpers (counterparts of Dynmap-GPU's dump / column / topblocks / colblocks / encodetest). No GPU needed:
##   godot --headless -s scripts/dev_tools.gd -- <command> [options]
##   dump        --region FILE.mca --chunk cx,cz              NBT tree of one chunk (array sizes instead of contents)
##   column      --region FILE.mca --chunk cx,cz              per-section palette size / light availability
##   topblocks   --region-dir DIR --tile tx,ty                top non-air block of every column of one iso_S_90_lowres tile
##   colblocks   --region-dir DIR --chunk cx,cz --xz x,z      block state changes along one column, with light
##   encodetest  --dir DIR_WITH_PNGS                          lossless WebP vs PNG sizes and round trip
## Common: --data-dir DIR (output of tools/build_data.py and tools/build_assets.py; default res://data)


func _initialize() -> void:
	var argv := OS.get_cmdline_user_args()
	if argv.is_empty():
		print("usage: dev_tools.gd -- dump|column|topblocks|colblocks|encodetest [options]")
		quit(2)
		return
	var cmd := argv[0]
	var args := _parse(argv.slice(1))
	var data_dir: String = args.get("data-dir", ProjectSettings.globalize_path("res://data"))
	match cmd:
		"dump":
			_dump(args)
		"column":
			_column(args, data_dir)
		"topblocks":
			_topblocks(args, data_dir)
		"colblocks":
			_colblocks(args, data_dir)
		"encodetest":
			_encodetest(args)
		_:
			print("unknown command %s" % cmd)
			quit(2)
			return
	quit(0)


func _chunk_raw(args: Dictionary) -> PackedByteArray:
	var cc := String(args.get("chunk", "0,0")).split(",")
	var rg := FileAccess.get_file_as_bytes(args["region"])
	return WorldReader.raw_chunk(rg, int(cc[0]) & 31, int(cc[1]) & 31)


func _dump(args: Dictionary) -> void:
	var raw := _chunk_raw(args)
	if raw.is_empty():
		print("chunk not present")
		return
	var out := PackedStringArray()
	_dump_value(Nbt.parse(raw), 0, out)
	print("\n".join(out))


func _dump_value(v: Variant, indent: int, out: PackedStringArray) -> void:
	var pad := "  ".repeat(indent)
	if v is Dictionary:
		for k in v:
			var x = v[k]
			if x is Dictionary or x is Array:
				out.append("%s%s:" % [pad, k])
				_dump_value(x, indent + 1, out)
			elif x is PackedByteArray:
				out.append("%s%s: bytes[%d]" % [pad, k, x.size()])
			elif x is PackedInt32Array:
				out.append("%s%s: int[%d]" % [pad, k, x.size()])
			else:
				out.append("%s%s: %s" % [pad, k, str(x)])
	elif v is Array:
		out.append("%s[list of %d]" % [pad, v.size()])
		if v.size() > 0:
			_dump_value(v[0], indent + 1, out)
	else:
		out.append("%s%s" % [pad, str(v)])


func _column(args: Dictionary, _data_dir: String) -> void:
	var raw := _chunk_raw(args)
	if raw.is_empty():
		print("no chunk")
		return
	var root := Nbt.parse(raw)
	for s in root.get("sections", []):
		var bs: Dictionary = s.get("block_states", {})
		var pal: Array = bs.get("palette", [])
		var sky := -1
		if s.has("SkyLight"):
			sky = 0
			for b in (s["SkyLight"] as PackedByteArray):
				if b != 0:
					sky += 1
		print("Y=%d palette=%d skylight_nonzero_bytes=%d keys=%s" % [s["Y"], pal.size(), sky, str(s.keys())])
		if pal.size() > 1:
			print("   palette: %s" % str(pal).substr(0, 900))


func _world(args: Dictionary, data_dir: String) -> Array:
	var table := BlockTable.new()
	table.load_dir(data_dir)
	var reg := StateRegistry.new()
	reg.load_dir(data_dir)
	var world := WorldReader.new(args["region-dir"], table)
	world.registry = reg
	return [world, reg]


func _topblocks(args: Dictionary, data_dir: String) -> void:
	var wr := _world(args, data_dir)
	var world: WorldReader = wr[0]
	var reg: StateRegistry = wr[1]
	var t := String(args.get("tile", "0,0")).split(",")
	var tx := int(t[0])
	var ty := int(t[1])
	# iso_S_90_lowres: 4 px per block, tile (tx, ty) covers x in [32tx, 32tx+32), z in [-(32ty+32), -32ty)
	for wz in range(-(ty * 32 + 32), -ty * 32 + 1):
		for wx in range(tx * 32, tx * 32 + 32):
			var c := world.chunk(wx >> 4, wz >> 4)
			if c == null:
				continue
			var y := c.max_y() - 1
			while y >= c.min_y():
				var b := c.block(wx & 15, y, wz & 15)
				if b != 0:
					print("%d %d %d %s" % [wx, wz, y, reg.s_name[b]])
					break
				y -= 1


func _colblocks(args: Dictionary, data_dir: String) -> void:
	var wr := _world(args, data_dir)
	var world: WorldReader = wr[0]
	var reg: StateRegistry = wr[1]
	var cc := String(args.get("chunk", "0,0")).split(",")
	var xz := String(args.get("xz", "0,0")).split(",")
	var c := world.chunk(int(cc[0]), int(cc[1]))
	if c == null:
		print("no chunk")
		return
	var x := int(xz[0])
	var z := int(xz[1])
	var last := -1
	for y in range(c.min_y(), c.max_y()):
		var b := c.block(x, y, z)
		if b != last:
			print("y=%d: state %d %s quads=%d opaque=%d air=%d" % [y, b, reg.s_name[b], reg.s_qmeta[b].size() / 5, reg.s_opaque[b], reg.s_air[b]])
			last = b
		if y >= -66 and y <= -56:
			print("     light y=%d: %d" % [y, c.light(x, y, z)])


func _encodetest(args: Dictionary) -> void:
	var png_total := 0
	var webp_total := 0
	var n := 0
	var t_enc := 0
	for f in DirAccess.get_files_at(args["dir"]):
		if not f.ends_with(".png"):
			continue
		var img := Image.load_from_file(String(args["dir"]).path_join(f))
		img.convert(Image.FORMAT_RGBA8)
		var png := img.save_png_to_buffer()
		var t0 := Time.get_ticks_usec()
		var webp := TileCodec.encode_webp(img)
		t_enc += Time.get_ticks_usec() - t0
		var back := Image.new()
		back.load_webp_from_buffer(webp)
		back.convert(Image.FORMAT_RGBA8)
		var a := img.get_data()
		var b := back.get_data()
		var ok := true
		for i in range(0, a.size(), 4):
			if (a[i + 3] == 0 and b[i + 3] == 0):
				continue
			if a[i] != b[i] or a[i + 1] != b[i + 1] or a[i + 2] != b[i + 2] or a[i + 3] != b[i + 3]:
				ok = false
				break
		if not ok:
			print("round trip mismatch: %s" % f)
		png_total += png.size()
		webp_total += webp.size()
		n += 1
		if n >= 200:
			break
	print("%d tiles: lossless webp %d bytes, png %d bytes, webp encode %.1f ms total" % [n, webp_total, png_total, t_enc / 1000.0])


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
