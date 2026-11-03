class_name GpuWorld
extends RefCounted
## Packs the chunks covering a block rectangle (plus a one chunk border for neighbour light) into the flat
## buffers shaders/resolve_columns.glsl reads. Block data stays bit-packed; the GPU unpacks it.


static func pack(world: WorldReader, x0: int, z0: int, wb: int, hb: int) -> Dictionary:
	var gx0 := (x0 - 1) >> 4
	var gz0 := (z0 - 1) >> 4
	var gx1 := (x0 + wb) >> 4
	var gz1 := (z0 + hb) >> 4
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
			var c := world.chunk(gx0 + gx, gz0 + gz)
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
	}
