class_name WorldReader
extends RefCounted
## Reads Anvil region files and turns a rectangle of block columns into the layer buffer the GPU shader consumes.

const MAX_LAYERS := 5
const COL_WORDS := 16  # 5 layers * 3 words + count

var region_dir := ""
var table: BlockTable
var _regions := {}
var _chunks := {}
var stats := {"chunks": 0, "chunk_ms": 0.0}


func _init(dir: String, tbl: BlockTable) -> void:
	region_dir = dir
	table = tbl


func _region(rx: int, rz: int) -> PackedByteArray:
	var key := Vector2i(rx, rz)
	if _regions.has(key):
		return _regions[key]
	if _regions.size() >= 4:
		_regions.clear()
	var path := region_dir.path_join("r.%d.%d.mca" % [rx, rz])
	var data := PackedByteArray()
	if FileAccess.file_exists(path):
		data = FileAccess.get_file_as_bytes(path)
	_regions[key] = data
	return data


func chunk(cx: int, cz: int) -> ChunkData:
	var key := Vector2i(cx, cz)
	if _chunks.has(key):
		return _chunks[key]
	if _chunks.size() >= 512:
		_chunks.clear()
	var c: ChunkData = null
	var rg := _region(cx >> 5, cz >> 5)
	if rg.size() >= 8192:
		var idx := (cx & 31) + (cz & 31) * 32
		var off := ((rg[idx * 4] << 16) | (rg[idx * 4 + 1] << 8) | rg[idx * 4 + 2]) * 4096
		var sectors := rg[idx * 4 + 3]
		if off != 0 and sectors != 0 and off + 5 <= rg.size():
			var ln := (rg[off] << 24) | (rg[off + 1] << 16) | (rg[off + 2] << 8) | rg[off + 3]
			var comp := rg[off + 4] & 0x7f
			if ln >= 1 and off + 4 + ln <= rg.size():
				var body := rg.slice(off + 5, off + 4 + ln)
				var raw := PackedByteArray()
				if comp == 2:
					raw = body.decompress_dynamic(-1, FileAccess.COMPRESSION_DEFLATE)
				elif comp == 1:
					raw = body.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP)
				elif comp == 3:
					raw = body
				else:
					push_warning("unsupported chunk compression %d at %d,%d" % [comp, cx, cz])
				if not raw.is_empty():
					var t0 := Time.get_ticks_usec()
					c = ChunkData.decode(raw, cx, cz, table)
					stats["chunks"] += 1
					stats["chunk_ms"] += (Time.get_ticks_usec() - t0) / 1000.0
	_chunks[key] = c
	return c


func block_at(x: int, y: int, z: int) -> int:
	var c := chunk(x >> 4, z >> 4)
	if c == null:
		return 0
	return c.block(x & 15, y, z & 15)


## max(sky, block) light; 15 where the chunk is not loaded (like Dynmap's border handling).
func light_at(x: int, y: int, z: int) -> int:
	var c := chunk(x >> 4, z >> 4)
	if c == null:
		return 15
	return c.light(x & 15, y, z & 15)


func biome_at(x: int, y: int, z: int) -> int:
	var c := chunk(x >> 4, z >> 4)
	if c == null:
		return 0
	return c.biome(x & 15, y, z & 15)


## Dynmap SEMITRANSPARENT light: brightest of the cell above and its four side neighbours at (x,y,z).
func _semi_light(x: int, y: int, z: int) -> int:
	return maxi(maxi(light_at(x, y + 1, z), light_at(x - 1, y, z)), \
		maxi(maxi(light_at(x + 1, y, z), light_at(x, y, z - 1)), light_at(x, y, z + 1)))


## Light as Dynmap samples a cell for an upward face (see Dynmap-GPU mesh.rs sample_light, normal = up).
func _sample_light(x: int, y: int, z: int) -> int:
	var id := block_at(x, y, z)
	var k := table.kind[id]
	if k == BlockTable.KIND_FLUID:
		return _semi_light(x, y, z)
	if k == BlockTable.KIND_SOLID:
		if table.kind[block_at(x, y + 1, z)] == BlockTable.KIND_FLUID:
			return _semi_light(x, y + 1, z)
		return light_at(x, y + 1, z)
	return light_at(x, y, z)


func _face_light(x: int, y: int, z: int) -> int:
	return _sample_light(x, y, z) | (_sample_light(x - 1, y, z) << 4) | (_sample_light(x + 1, y, z) << 8) \
		| (_sample_light(x, y, z - 1) << 12) | (_sample_light(x, y, z + 1) << 16)


func _top_y(x: int, z: int) -> int:
	var c := chunk(x >> 4, z >> 4)
	if c == null:
		return -100000
	return c.max_y() - 1


## Builds the layer words for the block rectangle [x0,x0+w) x [z0,z0+h). Column index = (z - z0) * w + (x - x0).
func build_columns(x0: int, z0: int, w: int, h: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(w * h * COL_WORDS)
	for dz in h:
		for dx in w:
			var x := x0 + dx
			var z := z0 + dz
			var base := (dz * w + dx) * COL_WORDS
			var n := 0
			var y := _top_y(x, z)
			var c := chunk(x >> 4, z >> 4)
			if c == null:
				continue
			var lx := x & 15
			var lz := z & 15
			var min_y := c.min_y()
			while y >= min_y and n < MAX_LAYERS:
				var s := c.section_at(y)
				if s == null or (s.raw_data.is_empty() and table.kind[s.uniform] == BlockTable.KIND_NONE):
					y = ((y >> 4) << 4) - 1  # skip an empty section
					continue
				var id := s.block(lx, y & 15, lz)
				var k := table.kind[id]
				if k == BlockTable.KIND_NONE:
					y -= 1
					continue
				var tex := table.tex[id]
				var biome := c.biome(lx, y, lz)
				var tint := table.tint_color(id, biome)
				var w0 := tex
				if (y & 1) == 0:
					w0 |= 1 << 19
				var light: int
				if k == BlockTable.KIND_FLUID:
					w0 |= 1 << 20  # no face shading, no smooth lighting
					light = _semi_light(x, y, z)
				else:
					light = _face_light(x, y, z)
				out[base + n * 3] = w0
				out[base + n * 3 + 1] = tint
				out[base + n * 3 + 2] = light
				n += 1
				if k == BlockTable.KIND_SOLID and table.tex_opaque[tex] == 1:
					break
				if k == BlockTable.KIND_FLUID:
					# one layer per water column; continue below the surface
					while y > min_y and table.kind[block_at(x, y - 1, z)] == BlockTable.KIND_FLUID:
						y -= 1
				y -= 1
			out[base + 15] = n
	return out
