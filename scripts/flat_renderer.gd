class_name FlatRenderer
extends RefCounted
## Renders Dynmap "iso_S_90_lowres" tiles with a compute shader on a local RenderingDevice.

const TILE := 128
const SCALE := 4  # pixels per block
const BLOCKS_PER_TILE := TILE / SCALE

var rd: RenderingDevice
var shader: RID
var pipeline: RID
var atlas_buf: RID
var table: BlockTable
var world: WorldReader
var device_name := ""
var gpu_ms := 0.0
var cpu_ms := 0.0


func setup(tbl: BlockTable, w: WorldReader) -> bool:
	table = tbl
	world = w
	rd = RenderingServer.create_local_rendering_device()
	if rd == null:
		push_error("no RenderingDevice (running with --headless? use a display driver, see docker/run.sh)")
		return false
	device_name = rd.get_device_name()
	var src := load("res://shaders/flat_tile.glsl") as RDShaderFile
	var spirv := src.get_spirv()
	if spirv.compile_error_compute != "":
		push_error(spirv.compile_error_compute)
		return false
	shader = rd.shader_create_from_spirv(spirv)
	pipeline = rd.compute_pipeline_create(shader)
	atlas_buf = rd.storage_buffer_create(table.atlas.size(), table.atlas)
	return true


## Renders tiles [tx0, tx0+ntx) x [ty0, ty0+nty); returns one RGBA8 Image per tile, row-major (ty then tx).
func render(tx0: int, ty0: int, ntx: int, nty: int) -> Array[Image]:
	var t0 := Time.get_ticks_usec()
	var wb := ntx * BLOCKS_PER_TILE
	var hb := nty * BLOCKS_PER_TILE
	var cols := world.build_columns(tx0 * BLOCKS_PER_TILE, -(ty0 + nty) * BLOCKS_PER_TILE, wb, hb)
	var t1 := Time.get_ticks_usec()
	cpu_ms += (t1 - t0) / 1000.0

	var pw := ntx * TILE
	var ph := nty * TILE
	var col_bytes := cols.to_byte_array()
	var col_buf := rd.storage_buffer_create(col_bytes.size(), col_bytes)
	var out_buf := rd.storage_buffer_create(pw * ph * 4)
	var uniforms: Array[RDUniform] = []
	for pair in [[0, col_buf], [1, atlas_buf], [2, out_buf]]:
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = pair[0]
		u.add_id(pair[1])
		uniforms.append(u)
	var set_rid := rd.uniform_set_create(uniforms, shader, 0)
	var pc := PackedInt32Array([pw, ph, wb, hb]).to_byte_array()

	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, set_rid, 0)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, ceili(pw / 8.0), ceili(ph / 8.0), 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	var bytes := rd.buffer_get_data(out_buf)
	gpu_ms += (Time.get_ticks_usec() - t1) / 1000.0

	rd.free_rid(set_rid)
	rd.free_rid(col_buf)
	rd.free_rid(out_buf)

	var full := Image.create_from_data(pw, ph, false, Image.FORMAT_RGBA8, bytes)
	# image row 0 is the northernmost row, i.e. the largest tile y
	var tiles: Array[Image] = []
	for ty in nty:
		for tx in ntx:
			tiles.append(full.get_region(Rect2i(tx * TILE, (nty - 1 - ty) * TILE, TILE, TILE)))
	return tiles
