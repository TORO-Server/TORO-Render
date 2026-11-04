class_name DevCmd
extends RefCounted
## Debugging helpers (dump / column / topblocks / colblocks / encodetest). Most need no GPU.
##   dev dump        --region FILE.mca --chunk cx,cz              NBT tree of one chunk (array sizes instead of contents)
##   dev column      --region FILE.mca --chunk cx,cz              per-section palette size / light availability
##   dev topblocks   --region-dir DIR --tile tx,ty               top non-air block of every column of one iso_S_90_lowres tile
##   dev colblocks   --region-dir DIR --chunk cx,cz --xz x,z      block state changes along one column, with light
##   dev encodetest  --dir DIR_WITH_PNGS                          lossless WebP vs PNG sizes and round trip
##   dev zoomtest    [--seed N]                                   GPU zoom shader vs the CPU reference on random tiles
##   dev dbtest      --db-port P --map-id N [--scratch-id 99001]  read-only checks against a real map (tile decode + hash,
##                                                                recomputing a stored zoom-1 parent), then a write/read/delete
##                                                                round trip that touches only the scratch MapID
## Common: --data-dir DIR (output of `build-data`; default res://data)


static func run(a: Args) -> int:
	return DevCmd.new()._dispatch(a)


func _dispatch(a: Args) -> int:
	var args := a.to_dict()
	var data_dir: String = a.text("data-dir", ProjectSettings.globalize_path("res://data"))
	match a.text("sub"):
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
		"zoomtest":
			return _zoomtest(a)
		"dbtest":
			return _dbtest(a)
		_:
			print("usage: dev dump|column|topblocks|colblocks|encodetest|zoomtest [options]")
			return 2
	return 0

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

## GPU zoom shader against the CPU reference on random tiles (every child present or missing in turn).
func _zoomtest(a: Args) -> int:
	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		print("no RenderingDevice")
		return 1
	var rng := RandomNumberGenerator.new()
	rng.seed = a.integer("seed", 1)
	var zb := ZoomBuilder.new(null, rd)
	var cases := []
	for n in 6:
		var kids := []
		for k in 4:
			var px := PackedByteArray()
			px.resize(128 * 128 * 4)
			if n == 0 or rng.randi() % 4 != 0:
				for i in px.size():
					px[i] = rng.randi() & 255
			kids.append(px if (n != 1 or k != 2) else PackedByteArray())
		cases.append(kids)
	var gpu := zb.combine(cases)
	var bad := 0
	for i in cases.size():
		if gpu[i] != ZoomBuilder.combine_cpu(cases[i]):
			bad += 1
	print("zoomtest: %d parents, %d differ between GPU and CPU" % [cases.size(), bad])
	return 0 if bad == 0 else 1

func _dbtest(a: Args) -> int:
	var ctx := Context.create(a, 4.0, -1)
	var store := ctx.store
	store.map_id = a.integer("map-id", 1)
	if not store.connect_db():
		print("connect failed: ", store.error)
		return 1
	print("world of map %d: '%s'" % [store.map_id, store.world_name()])
	# a stored zoom-1 parent must equal the mean of its four stored children
	var rows := store._run("SELECT x,y,HashCode FROM dynmap_Tiles WHERE MapID=%d AND zoom=1 LIMIT 3" % store.map_id)
	var rd := RenderingServer.create_local_rendering_device()
	var zb := ZoomBuilder.new(store, rd)
	var ok := true
	for row in rows:
		var p := Vector2i(Mysql.as_int(row[0]), Mysql.as_int(row[1]))
		var want := Mysql.as_int(row[2])
		var kids := ZoomBuilder.children_of(p, 0)
		var imgs := store.read_images(0, kids)
		var bytes := []
		for c in kids:
			bytes.append(imgs[c].get_data() if imgs.has(c) else PackedByteArray())
		var px: PackedByteArray = zb.combine([bytes])[0]
		var got := TileCodec.crc_hash(px)
		print("parent %s: stored %d, recomputed %d (%d/4 children) %s" % [p, want, got, imgs.size(), "OK" if got == want else "DIFFERS"])
		ok = ok and got == want
		# the stored child's own hash must match its decoded pixels
		for c in imgs:
			var h: int = store.hashes(0, [c])[c]
			var h2 := TileCodec.crc_hash(imgs[c].get_data())
			if h != h2:
				print("  child %s: stored hash %d, decoded %d" % [c, h, h2])
	# write / read / delete round trip on the scratch map
	store.map_id = a.integer("scratch-id", 99001)
	var img := Image.create(128, 128, false, Image.FORMAT_RGBA8)
	img.fill(Color8(10, 200, 30, 255))
	var data := img.get_data()
	var hash := TileCodec.crc_hash(data)
	store.write(0, [{"x": 7, "y": -3, "hash": hash, "webp": TileCodec.encode_webp(img)}], int(Time.get_unix_time_from_system() * 1000.0))
	var back := store.read_images(0, [Vector2i(7, -3)])
	var stored := store.hashes(0, [Vector2i(7, -3)])
	var same: bool = back.has(Vector2i(7, -3)) and back[Vector2i(7, -3)].get_data() == data and stored.get(Vector2i(7, -3), -1) == hash
	store.delete(0, [Vector2i(7, -3)])
	var gone := store.hashes(0, [Vector2i(7, -3)]).is_empty()
	print("scratch round trip: pixels+hash %s, deleted %s, error '%s'" % ["OK" if same else "DIFFER", gone, store.error])
	return 0 if (ok and same and gone and store.error == "") else 1
