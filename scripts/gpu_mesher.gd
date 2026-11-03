class_name GpuMesher
extends RefCounted
## Host side of shaders/mesh_chunks.glsl: packs the chunks around a list of target chunks, runs the two mesher passes
## (count, emit) and hands the quad buffers to the raster pass without leaving the GPU.

var rd: RenderingDevice
var reg: StateRegistry
var table: BlockTable
var topdown := false
var _shader := RID()
var _pipe := RID()
var _tclass_buf := RID()
var _bcol_buf := RID()
var _n_biomes := 0
var _tables := {}
var _table_bufs: Array[RID] = []
var _tables_count := -1
var timing := {"pack_ms": 0.0, "mesh_ms": 0.0}


func setup(rd_: RenderingDevice, reg_: StateRegistry, tbl: BlockTable, tex_class: PackedByteArray) -> bool:
	rd = rd_
	reg = reg_
	table = tbl
	var file := load("res://shaders/mesh_chunks.glsl") as RDShaderFile
	var spirv := file.get_spirv()
	if spirv.compile_error_compute != "":
		push_error("mesh_chunks.glsl: %s" % spirv.compile_error_compute)
		return false
	_shader = rd.shader_create_from_spirv(spirv)
	_pipe = rd.compute_pipeline_create(_shader)
	var tc := PackedInt32Array()
	tc.resize(tex_class.size())
	for i in tex_class.size():
		tc[i] = tex_class[i]
	_tclass_buf = _buf(tc.to_byte_array())
	var bc := table.gpu_biome_colors()
	_n_biomes = bc.size() / 12
	_bcol_buf = _buf(bc)
	return true


func _buf(bytes: PackedByteArray) -> RID:
	if bytes.is_empty():
		bytes.resize(16)
	return rd.storage_buffer_create(bytes.size(), bytes)


func _u(binding: int, id: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(id)
	return u


func _ensure_tables() -> void:
	if _tables_count == reg.state_count():
		return
	for r in _table_bufs:
		rd.free_rid(r)
	_table_bufs.clear()
	_tables = reg.gpu_tables()
	_tables_count = _tables["count"]
	_table_bufs.append(_buf(_tables["sinfo"]))
	_table_bufs.append(_buf(_tables["qf"]))
	_table_bufs.append(_buf(_tables["qm"]))


## targets: chunks to mesh; offs: vec4 per target (map offset x, y, z-relative, 0).
## Returns {"nquads", "vf", "vi", "qchunk" (RIDs, caller frees), "trans" (bytes: 16 uints per translucent quad, see mesh_chunks.glsl)}.
func mesh(world: WorldReader, targets: Array[Vector2i], offs: PackedFloat32Array, row2: PackedFloat64Array, water_tex: int, lava_tex: int) -> Dictionary:
	var out := {"nquads": 0, "vf": RID(), "vi": RID(), "qchunk": RID(), "trans": PackedByteArray()}
	if targets.is_empty():
		return out
	var t0 := Time.get_ticks_usec()
	var set_chunks: Array[Vector2i] = []
	var seen := {}
	for c in targets:
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				var k := Vector2i(c.x + dx, c.y + dz)
				if not seen.has(k):
					seen[k] = true
					set_chunks.append(k)
	var packed := GpuWorld.pack_set(world, set_chunks)
	_ensure_tables()  # after packing: decoding may have interned new states
	var tgt := PackedInt32Array()
	for c in targets:
		tgt.append(c.x)
		tgt.append(c.y)
	var temp: Array[RID] = []
	for key in ["grid", "cmeta", "smeta", "pal", "data", "bytes"]:
		temp.append(_buf(packed[key]))
	var b_targets := _buf(tgt.to_byte_array())
	var b_offs := _buf(offs.to_byte_array())
	var b_counters := rd.storage_buffer_create(16, PackedInt32Array([0, 0, 0, 0]).to_byte_array())
	var gsize: Vector2i = packed["grid_size"]
	var gorg: Vector2i = packed["grid_origin"]
	var pc := PackedInt32Array([targets.size(), gorg.x, gorg.y, gsize.x, gsize.y, 1 if topdown else 0, 0, _n_biomes]).to_byte_array()
	var pcf := PackedFloat32Array([row2[0], row2[1], row2[2], 0.0]).to_byte_array()
	pc.append_array(pcf)
	pc.append_array(PackedInt32Array([water_tex, lava_tex, 0, 0]).to_byte_array())
	var t1 := Time.get_ticks_usec()
	timing["pack_ms"] += (t1 - t0) / 1000.0

	# pass 0: count
	var dummy := _buf(PackedByteArray())
	var uset := _make_set(temp, b_targets, b_offs, b_counters, dummy, dummy, dummy, dummy)
	_dispatch(uset, pc, targets.size())
	rd.submit()
	rd.sync()
	var cnt0 := rd.buffer_get_data(b_counters, 0, 8)
	var nq := cnt0.decode_u32(0)
	var nt := cnt0.decode_u32(4)
	rd.free_rid(uset)
	if nq == 0:
		for r in temp + [b_targets, b_offs, b_counters, dummy]:
			rd.free_rid(r)
		return out

	# pass 1: emit
	rd.buffer_update(b_counters, 0, 16, PackedInt32Array([0, 0, 0, 0]).to_byte_array())
	var vf := rd.storage_buffer_create(nq * 128)
	var vi := rd.storage_buffer_create(nq * 48)
	var qchunk := rd.storage_buffer_create(nq * 4)
	var trans := rd.storage_buffer_create(maxi(nt, 1) * 64)
	pc.encode_s32(24, 1)  # emit = 1 (7th int)
	var uset2 := _make_set(temp, b_targets, b_offs, b_counters, vf, vi, qchunk, trans)
	_dispatch(uset2, pc, targets.size())
	rd.submit()
	rd.sync()
	var counters := rd.buffer_get_data(b_counters, 0, 8)
	var emitted := counters.decode_u32(0)
	var ntrans := counters.decode_u32(4)
	if emitted != nq:
		push_warning("GPU mesher: count pass %d != emit pass %d quads" % [nq, emitted])
	if ntrans != nt:
		push_warning("GPU mesher: count pass %d translucent quads, emit pass %d" % [nt, ntrans])
		ntrans = mini(ntrans, nt)
	var tr := PackedByteArray()
	if ntrans > 0:
		tr = rd.buffer_get_data(trans, 0, ntrans * 64)
	rd.free_rid(uset2)  # before its buffers: freeing a buffer also frees the sets that use it
	for r in temp + [b_targets, b_offs, b_counters, dummy, trans]:
		rd.free_rid(r)
	timing["mesh_ms"] += (Time.get_ticks_usec() - t1) / 1000.0
	out["nquads"] = nq
	out["vf"] = vf
	out["vi"] = vi
	out["qchunk"] = qchunk
	out["trans"] = tr
	return out


func _make_set(packed_bufs: Array[RID], b_targets: RID, b_offs: RID, b_counters: RID, vf: RID, vi: RID, qchunk: RID, trans: RID) -> RID:
	var us: Array[RDUniform] = []
	for i in 6:
		us.append(_u(i, packed_bufs[i]))
	us.append(_u(6, _table_bufs[0]))
	us.append(_u(7, _table_bufs[1]))
	us.append(_u(8, _table_bufs[2]))
	us.append(_u(9, _bcol_buf))
	us.append(_u(10, b_targets))
	us.append(_u(11, _tclass_buf))
	us.append(_u(12, b_offs))
	us.append(_u(13, b_counters))
	us.append(_u(14, vf))
	us.append(_u(15, vi))
	us.append(_u(16, qchunk))
	us.append(_u(17, trans))
	return rd.uniform_set_create(us, _shader, 0)


func _dispatch(uset: RID, pc: PackedByteArray, ntargets: int) -> void:
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	rd.compute_list_bind_uniform_set(cl, uset, 0)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	var groups := ceili(ntargets * 256 / 64.0)
	# keep each dimension within the device limit
	rd.compute_list_dispatch(cl, mini(groups, 65535), maxi(1, ceili(groups / 65535.0)), 1)
	rd.compute_list_end()
