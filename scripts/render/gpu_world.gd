class_name GpuWorld
extends RefCounted
## Packs chunks into the flat buffers shaders/mesh_chunks.glsl reads. Block data stays bit-packed; the GPU unpacks it.


## Packs exactly the given chunks (plus nothing else): the caller lists targets and their neighbours. Chunks that are
## not in the set are absent from the grid (the shader treats them like missing chunks).
static func pack_set(world: WorldReader, chunks: Array[Vector2i]) -> Dictionary:
	var gx0 := 1 << 30
	var gz0 := 1 << 30
	var gx1 := -(1 << 30)
	var gz1 := -(1 << 30)
	for c in chunks:
		gx0 = mini(gx0, c.x)
		gz0 = mini(gz0, c.y)
		gx1 = maxi(gx1, c.x)
		gz1 = maxi(gz1, c.y)
	var want := {}
	for c in chunks:
		want[c] = true
	return _pack_grid(world, gx0, gz0, gx1, gz1, [0, 0, 0, 0], want)


static func _pack_grid(world: WorldReader, gx0: int, gz0: int, gx1: int, gz1: int, rect: Array, want: Dictionary = {}) -> Dictionary:
	var x0: int = rect[0]
	var z0: int = rect[1]
	var wb: int = rect[2]
	var hb: int = rect[3]
	var gw := gx1 - gx0 + 1
	var gh := gz1 - gz0 + 1
	var grid := PackedInt32Array()
	grid.resize(gw * gh)
	var cmeta := PackedInt32Array()
	var smeta := PackedInt32Array()
	var pal := PackedInt32Array()
	var data := PackedByteArray()
	var bytes := PackedByteArray()
	var nchunks := 0
	for gz in gh:
		for gx in gw:
			var c: ChunkData = null
			if want.is_empty() or want.has(Vector2i(gx0 + gx, gz0 + gz)):
				c = world.chunk(gx0 + gx, gz0 + gz)
			if c == null:
				grid[gz * gw + gx] = -1
				continue
			grid[gz * gw + gx] = nchunks
			nchunks += 1
			var nsec := c.sections.size()
			cmeta.append(smeta.size() / 8)
			cmeta.append(c.min_sec)
			cmeta.append(nsec)
			cmeta.append(c.sky_fill)
			for s in c.sections:
				if s == null:
					smeta.append_array([0, -1, 0, -1, -1, 0, 0, 0])
					continue
				var pal_off := pal.size()
				pal.append_array(s.pal)
				# the shader adds an index of `bits` bits to pal_off without a check: keep every such index inside this
				# section's palette (padding reads as state 0, air), however the block data was written
				if s.bits > 0:
					for _i in (1 << s.bits) - s.pal.size():
						pal.append(0)
				var data_off := -1
				if not s.raw_data.is_empty():
					data_off = data.size() / 4
					data.append_array(s.raw_data)
				var sky_off := -1
				if not s.sky.is_empty():
					sky_off = bytes.size()
					bytes.append_array(s.sky)
				var blk_off := -1
				if not s.blk.is_empty():
					blk_off = bytes.size()
					bytes.append_array(s.blk)
				var bio_off := bytes.size()
				bytes.append_array(s.biome_bytes())
				smeta.append_array([pal_off, data_off, s.bits, sky_off, blk_off, bio_off, s.uniform, 1])
	# storage buffers must not be empty
	if cmeta.is_empty():
		cmeta.append_array([0, 0, 0, 0])
	if smeta.is_empty():
		smeta.append_array([0, -1, 0, -1, -1, 0, 0, 0])
	if pal.is_empty():
		pal.append(0)
	if data.is_empty():
		data.resize(8)
	if bytes.is_empty():
		bytes.resize(4)
	return {
		"grid": grid.to_byte_array(),
		"cmeta": cmeta.to_byte_array(),
		"smeta": smeta.to_byte_array(),
		"pal": pal.to_byte_array(),
		"data": data,
		"bytes": bytes,
		"params": PackedInt32Array([x0, z0, wb, hb, gx0, gz0, gw, gh]).to_byte_array(),
		"grid_origin": Vector2i(gx0, gz0),
		"grid_size": Vector2i(gw, gh),
		"nchunks": nchunks,
	}
