class_name FlatRenderer
extends RefCounted
## Renders Dynmap "iso_S_90_lowres" tiles with compute shaders on a local RenderingDevice:
## resolve_columns.glsl (block columns -> layers) followed by flat_tile.glsl (layers -> pixels).

const TILE := 128
const SCALE := 4  # pixels per block
const BLOCKS_PER_TILE := TILE / SCALE

var rd: RenderingDevice
var resolve_shader: RID
var resolve_pipe: RID
var tile_shader: RID
var tile_pipe: RID
var atlas_buf: RID
var binfo_buf: RID
var bcol_buf: RID
var table: BlockTable
var world: WorldReader
var device_name := ""
var gpu_columns := true
var verify := false
var gpu_ms := 0.0
var cpu_ms := 0.0
var mismatched_columns := 0


func _compile(path: String) -> RID:
	var spirv := (load(path) as RDShaderFile).get_spirv()
	if spirv.compile_error_compute != "":
		push_error("%s: %s" % [path, spirv.compile_error_compute])
		return RID()
	return rd.shader_create_from_spirv(spirv)


func setup(tbl: BlockTable, w: WorldReader) -> bool:
	table = tbl
	world = w
	rd = RenderingServer.create_local_rendering_device()
	if rd == null:
		push_error("no RenderingDevice (running with --headless? use a display driver, see docker/run.sh)")
		return false
	device_name = rd.get_device_name()
	tile_shader = _compile("res://shaders/flat_tile.glsl")
	resolve_shader = _compile("res://shaders/resolve_columns.glsl")
	if not tile_shader.is_valid() or not resolve_shader.is_valid():
		return false
	tile_pipe = rd.compute_pipeline_create(tile_shader)
	resolve_pipe = rd.compute_pipeline_create(resolve_shader)
	atlas_buf = rd.storage_buffer_create(table.atlas.size(), table.atlas)
	var bi := table.gpu_block_info()
	binfo_buf = rd.storage_buffer_create(bi.size(), bi)
	var bc := table.gpu_biome_colors()
	bcol_buf = rd.storage_buffer_create(bc.size(), bc)
	return true


func _uniform_set(shader: RID, bufs: Array) -> RID:
	var uniforms: Array[RDUniform] = []
	for i in bufs.size():
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = i
		u.add_id(bufs[i])
		uniforms.append(u)
	return rd.uniform_set_create(uniforms, shader, 0)


func _buf(bytes: PackedByteArray) -> RID:
	return rd.storage_buffer_create(maxi(bytes.size(), 4), bytes)


## Renders tiles [tx0, tx0+ntx) x [ty0, ty0+nty); returns one RGBA8 Image per tile, row-major (ty then tx).
func render(tx0: int, ty0: int, ntx: int, nty: int) -> Array[Image]:
	var wb := ntx * BLOCKS_PER_TILE
	var hb := nty * BLOCKS_PER_TILE
	var bx0 := tx0 * BLOCKS_PER_TILE
	var bz0 := -(ty0 + nty) * BLOCKS_PER_TILE
	var pw := ntx * TILE
	var ph := nty * TILE
	var temp: Array[RID] = []

	var t0 := Time.get_ticks_usec()
	var cols_buf: RID
	var resolve_set := RID()
	var resolve_pc := PackedByteArray()
	var cpu_cols := PackedInt32Array()
	if gpu_columns:
		var packed := GpuWorld.pack(world, bx0, bz0, wb, hb)
		var bufs := [_buf(packed["grid"]), _buf(packed["cmeta"]), _buf(packed["smeta"]), _buf(packed["pal"]),
			_buf(packed["data"]), _buf(packed["bytes"]), binfo_buf, bcol_buf]
		cols_buf = rd.storage_buffer_create(wb * hb * WorldReader.COL_WORDS * 4)
		bufs.append(cols_buf)
		resolve_set = _uniform_set(resolve_shader, bufs)
		resolve_pc = packed["params"]
		for b in [0, 1, 2, 3, 4, 5]:
			temp.append(bufs[b])
	else:
		cpu_cols = world.build_columns(bx0, bz0, wb, hb)
		var cb := cpu_cols.to_byte_array()
		cols_buf = rd.storage_buffer_create(cb.size(), cb)
	var t1 := Time.get_ticks_usec()
	cpu_ms += (t1 - t0) / 1000.0

	var out_buf := rd.storage_buffer_create(pw * ph * 4)
	var tile_set := _uniform_set(tile_shader, [cols_buf, atlas_buf, out_buf])
	var tile_pc := PackedInt32Array([pw, ph, wb, hb]).to_byte_array()

	var cl := rd.compute_list_begin()
	if gpu_columns:
		rd.compute_list_bind_compute_pipeline(cl, resolve_pipe)
		rd.compute_list_bind_uniform_set(cl, resolve_set, 0)
		rd.compute_list_set_push_constant(cl, resolve_pc, resolve_pc.size())
		rd.compute_list_dispatch(cl, ceili(wb / 8.0), ceili(hb / 8.0), 1)
		rd.compute_list_add_barrier(cl)
	rd.compute_list_bind_compute_pipeline(cl, tile_pipe)
	rd.compute_list_bind_uniform_set(cl, tile_set, 0)
	rd.compute_list_set_push_constant(cl, tile_pc, tile_pc.size())
	rd.compute_list_dispatch(cl, ceili(pw / 8.0), ceili(ph / 8.0), 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	var bytes := rd.buffer_get_data(out_buf)
	gpu_ms += (Time.get_ticks_usec() - t1) / 1000.0

	if verify and gpu_columns:
		var gpu_cols := rd.buffer_get_data(cols_buf).to_int32_array()
		var ref := world.build_columns(bx0, bz0, wb, hb)
		var bad := 0
		for c in wb * hb:
			var o := c * WorldReader.COL_WORDS
			for k in WorldReader.COL_WORDS:
				if gpu_cols[o + k] != ref[o + k]:
					bad += 1
					if mismatched_columns + bad <= 3:
						print("column mismatch x=%d z=%d word %d gpu=%d cpu=%d" % [bx0 + c % wb, bz0 + c / wb, k, gpu_cols[o + k], ref[o + k]])
					break
		mismatched_columns += bad

	for r in [tile_set, resolve_set, cols_buf, out_buf] + temp:
		if r.is_valid():
			rd.free_rid(r)

	var full := Image.create_from_data(pw, ph, false, Image.FORMAT_RGBA8, bytes)
	# image row 0 is the northernmost row, i.e. the largest tile y
	var tiles: Array[Image] = []
	for ty in nty:
		for tx in ntx:
			tiles.append(full.get_region(Rect2i(tx * TILE, (nty - 1 - ty) * TILE, TILE, TILE)))
	return tiles
