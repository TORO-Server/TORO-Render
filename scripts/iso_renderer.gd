class_name IsoRenderer
extends RefCounted
## Renders Dynmap tiles of any perspective (flat or oblique) by rasterising baked block-model quads on a local
## RenderingDevice. Port of Dynmap-GPU render.rs + gpu.rs: chunk meshes -> orthographic raster with a depth buffer,
## opaque pass then back-to-front translucent pass, premultiplied blending, un-premultiplied readback.

const TILE := 128
const ATLAS_COLS := 64

var rd: RenderingDevice
var persp: Persp
var reg: StateRegistry
var table: BlockTable
var world: WorldReader
var mesher: Mesher
var device_name := ""
var min_y := -64
var max_y := 320
var front_ccw_vk := false
var verbose := false
var probe := PackedInt32Array()

var _shader := RID()
var _pipe_opaque := RID()
var _pipe_trans := RID()
var _finish_shader := RID()
var _finish_pipe := RID()
var _atlas := RID()
var _sampler := RID()
var _fb_format := -1
var _fbs := {}
var _classes := PackedByteArray()
var _shadow := PackedInt32Array()
var _meshes := {}
var _stamps := {}
var _gen := 0
var timing := {"mesh_ms": 0.0, "gather_ms": 0.0, "gpu_ms": 0.0, "quads": 0}


static func brightness_table() -> PackedInt32Array:
	# Dynmap's default brightness table (DynmapWorld): 256 * (1-f1)/(f1*3+1), f1 = 1 - i/15, computed in f32
	var t := PackedInt32Array()
	t.resize(16)
	var buf := PackedFloat32Array()
	buf.resize(1)
	for i in 16:
		buf[0] = 1.0 - float(i) / 15.0
		var f1: float = buf[0]
		buf[0] = (1.0 - f1) / (f1 * 3.0 + 1.0)
		var v: float = buf[0]
		t[i] = clampi(int(256.0 * v), 0, 256)
	return t


func _compile(path: String) -> RID:
	var file := load(path) as RDShaderFile
	var spirv := file.get_spirv()
	for stage_err in [spirv.compile_error_vertex, spirv.compile_error_fragment, spirv.compile_error_compute]:
		if stage_err != "":
			push_error("%s: %s" % [path, stage_err])
			return RID()
	return rd.shader_create_from_spirv(spirv)


func setup(persp_: Persp, reg_: StateRegistry, tbl: BlockTable, w: WorldReader) -> bool:
	persp = persp_
	reg = reg_
	table = tbl
	world = w
	world.registry = reg
	rd = RenderingServer.create_local_rendering_device()
	if rd == null:
		push_error("no RenderingDevice (running with --headless? use a display driver, see docker/run.sh)")
		return false
	device_name = rd.get_device_name()
	_shader = _compile("res://shaders/raster.glsl")
	_finish_shader = _compile("res://shaders/finish.glsl")
	if not _shader.is_valid() or not _finish_shader.is_valid():
		return false
	_finish_pipe = rd.compute_pipeline_create(_finish_shader)
	_shadow = brightness_table()
	_build_atlas()
	var sampler_state := RDSamplerState.new()
	_sampler = rd.sampler_create(sampler_state)
	mesher = Mesher.new(reg, table)
	mesher.topdown = persp.inclination >= 89.9
	mesher.tex_class = _classes
	world.chunk_cache_limit = 1500
	return true


## alpha-weighted box resample of one 16x16 RGBA texture to s x s (Dynmap-GPU assets.rs resample)
func _resample(t: int, s: int) -> PackedByteArray:
	var src := reg.tex_rgba
	var base := t * 1024
	var out := PackedByteArray()
	out.resize(s * s * 4)
	if s == 16:
		for i in 1024:
			out[i] = src[base + i]
		return out
	var r := 16 / s
	for y in s:
		for x in s:
			var sr := 0
			var sg := 0
			var sb := 0
			var sa := 0
			for yy in r:
				for xx in r:
					var o := base + ((y * r + yy) * 16 + x * r + xx) * 4
					var a: int = src[o + 3]
					sr += src[o] * a
					sg += src[o + 1] * a
					sb += src[o + 2] * a
					sa += a
			var d := maxi(sa, 1)
			var oo := (y * s + x) * 4
			out[oo] = sr / d
			out[oo + 1] = sg / d
			out[oo + 2] = sb / d
			out[oo + 3] = sa / (r * r)
	return out


func _build_atlas() -> void:
	var s := persp.scale
	var n := reg.tex_names.size()
	var rows := (n + ATLAS_COLS - 1) / ATLAS_COLS
	var img := Image.create(ATLAS_COLS * s, rows * s, false, Image.FORMAT_RGBA8)
	_classes.resize(n)
	for t in n:
		var px := _resample(t, mini(s, 16))
		var opaque := false
		var partial := false
		for i in range(3, px.size(), 4):
			if px[i] == 255:
				opaque = true
			elif px[i] != 0:
				partial = true
		_classes[t] = (1 if opaque else 0) | (2 if partial else 0)
		var cell := Image.create_from_data(s, s, false, Image.FORMAT_RGBA8, px)
		img.blit_rect(cell, Rect2i(0, 0, s, s), Vector2i((t % ATLAS_COLS) * s, (t / ATLAS_COLS) * s))
	var fmt := RDTextureFormat.new()
	fmt.width = img.get_width()
	fmt.height = img.get_height()
	fmt.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	_atlas = rd.texture_create(fmt, RDTextureView.new(), [img.get_data()])


func _get_fb(w: int, h: int) -> Dictionary:
	var key := Vector2i(w, h)
	if _fbs.has(key):
		return _fbs[key]
	if _fbs.size() >= 2:
		for k in _fbs:
			var old: Dictionary = _fbs[k]
			for r in [old["fb"], old["color"], old["depth"]]:
				rd.free_rid(r)
		_fbs.clear()
	var cf := RDTextureFormat.new()
	cf.width = w
	cf.height = h
	cf.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	cf.usage_bits = RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var color := rd.texture_create(cf, RDTextureView.new())
	var df := RDTextureFormat.new()
	df.width = w
	df.height = h
	df.format = RenderingDevice.DATA_FORMAT_D32_SFLOAT
	df.usage_bits = RenderingDevice.TEXTURE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT
	var depth := rd.texture_create(df, RDTextureView.new())
	var fb := rd.framebuffer_create([color, depth])
	if _fb_format < 0:
		_fb_format = rd.framebuffer_get_format(fb)
		_pipe_opaque = _make_pipeline(false)
		_pipe_trans = _make_pipeline(true)
	var d := {"fb": fb, "color": color, "depth": depth}
	_fbs[key] = d
	return d


func _make_pipeline(trans: bool) -> RID:
	var rs := RDPipelineRasterizationState.new()
	rs.cull_mode = RenderingDevice.POLYGON_CULL_BACK
	rs.front_face = RenderingDevice.POLYGON_FRONT_FACE_COUNTER_CLOCKWISE if (persp.front_ccw() != front_ccw_vk) else RenderingDevice.POLYGON_FRONT_FACE_CLOCKWISE
	var ms := RDPipelineMultisampleState.new()
	var ds := RDPipelineDepthStencilState.new()
	ds.enable_depth_test = true
	ds.enable_depth_write = not trans
	ds.depth_compare_operator = RenderingDevice.COMPARE_OP_GREATER
	var cb := RDPipelineColorBlendState.new()
	var att := RDPipelineColorBlendStateAttachment.new()
	if trans:
		att.enable_blend = true
		att.src_color_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
		att.dst_color_blend_factor = RenderingDevice.BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
		att.color_blend_op = RenderingDevice.BLEND_OP_ADD
		att.src_alpha_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
		att.dst_alpha_blend_factor = RenderingDevice.BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
		att.alpha_blend_op = RenderingDevice.BLEND_OP_ADD
	cb.attachments = [att]
	var sc := RDPipelineSpecializationConstant.new()
	sc.constant_id = 0
	sc.value = trans
	return rd.render_pipeline_create(_shader, _fb_format, RenderingDevice.INVALID_FORMAT_ID, RenderingDevice.RENDER_PRIMITIVE_TRIANGLES, rs, ms, ds, cb, 0, 0, [sc])


## Chunks whose volume can project into the map-space rectangle (render.rs needed_chunks).
func needed_chunks(x0: float, y0: float, x1: float, y1: float) -> Array[Vector2i]:
	var s := float(persp.scale)
	var wxmin := INF
	var wxmax := -INF
	var wzmin := INF
	var wzmax := -INF
	var base_dz := persp.map_to_world(0.0, 0.0, 1.0)
	for mx in [x0 - s, x1 + s]:
		for my in [y0 - s, y1 + s]:
			for wy in [min_y - 1.0, max_y + 1.0]:
				var b := persp.map_to_world(mx, my, 0.0)
				var mz: float = (wy - b[1]) / base_dz[1] if absf(base_dz[1]) > 1e-12 else 0.0
				var w := persp.map_to_world(mx, my, mz)
				wxmin = minf(wxmin, w[0])
				wxmax = maxf(wxmax, w[0])
				wzmin = minf(wzmin, w[2])
				wzmax = maxf(wzmax, w[2])
	var cx0 := floori(wxmin / 16.0) - 1
	var cx1 := floori(wxmax / 16.0) + 1
	var cz0 := floori(wzmin / 16.0) - 1
	var cz1 := floori(wzmax / 16.0) + 1
	var out: Array[Vector2i] = []
	for cz in range(cz0, cz1 + 1):
		for cx in range(cx0, cx1 + 1):
			var mnx := INF
			var mxx := -INF
			var mny := INF
			var mxy := -INF
			for wx in [cx * 16.0, cx * 16.0 + 16.0]:
				for wz in [cz * 16.0, cz * 16.0 + 16.0]:
					for wy in [float(min_y), float(max_y)]:
						var m := persp.world_to_map(wx, wy, wz)
						mnx = minf(mnx, m[0])
						mxx = maxf(mxx, m[0])
						mny = minf(mny, m[1])
						mxy = maxf(mxy, m[1])
			if mxx >= x0 - s and mnx <= x1 + s and mxy >= y0 - s and mny <= y1 + s:
				out.append(Vector2i(cx, cz))
	return out


func _mesh(cx: int, cz: int) -> Variant:
	var key := Vector2i(cx, cz)
	_stamps[key] = _gen
	if _meshes.has(key):
		return _meshes[key]
	var nb := []
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			nb.append(world.chunk(cx + dx, cz + dz))
	var m = null
	if nb[4] != null:
		var t0 := Time.get_ticks_usec()
		var n := mesher.mesh_chunk(nb)
		timing["mesh_ms"] += (Time.get_ticks_usec() - t0) / 1000.0
		m = {"f": mesher.f, "iv": mesher.iv, "n": n, "trans": mesher.trans}
		if verbose:
			print("  meshed chunk %d,%d: %d quads, %.0f ms total" % [cx, cz, n, timing["mesh_ms"]])
	_meshes[key] = m
	return m


## Drops cached meshes/chunks not used during the last few renders; call once per mega-tile.
func next_generation() -> void:
	_gen += 1
	for key in _stamps.keys():
		if _stamps[key] < _gen - 3:
			_stamps.erase(key)
			_meshes.erase(key)


func _storage(bytes: PackedByteArray) -> RID:
	if bytes.is_empty():
		bytes = PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
	return rd.storage_buffer_create(bytes.size(), bytes)


static func _f32_key(v: float, seq: int) -> int:
	# sortable key of a float32 value (ties broken by seq, i.e. the stable order Rust's sort_by gives)
	var buf := PackedByteArray()
	buf.resize(4)
	buf.encode_float(0, v)
	var b := buf.decode_u32(0)
	b = (~b & 0xFFFFFFFF) if (b & 0x80000000) != 0 else (b | 0x80000000)
	return (b << 31) | seq


## Renders tiles [tx0, tx0+ntx) x [ty0, ty0+nty); one RGBA8 Image per tile, row-major (ty then tx).
func render(tx0: int, ty0: int, ntx: int, nty: int) -> Array[Image]:
	var w := ntx * TILE
	var h := nty * TILE
	var x0 := float(tx0 * TILE)
	var y0 := float(ty0 * TILE)
	var t0 := Time.get_ticks_usec()
	var chunks := needed_chunks(x0, y0, x0 + w, y0 + h)
	if verbose:
		print("render %d,%d %dx%d tiles: %d chunks needed" % [tx0, ty0, ntx, nty, chunks.size()])
	var m := persp.w2m
	# z extent of the chunk boxes (relative offsets keep float32 precise)
	var zlo := INF
	var zhi := -INF
	for c in chunks:
		for wx in [c.x * 16.0, c.x * 16.0 + 16.0]:
			for wz in [c.y * 16.0, c.y * 16.0 + 16.0]:
				for wy in [float(min_y), float(max_y)]:
					var z: float = m[6] * wx + m[7] * wy + m[8] * wz
					zlo = minf(zlo, z)
					zhi = maxf(zhi, z)
	if zlo > zhi:
		zlo = 0.0
		zhi = 1.0
	var zref := (zlo + zhi) * 0.5
	var zhalf := (zhi - zlo) * 0.5 + 4.0
	var vf := PackedFloat32Array()
	var vi := PackedInt32Array()
	var offs := PackedFloat32Array()
	var nquads := 0
	var trans_keys := PackedInt64Array()
	var seq := 0
	for c in chunks:
		var mesh = _mesh(c.x, c.y)
		if mesh == null or mesh["n"] == 0:
			continue
		var bx := c.x * 16.0
		var bz := c.y * 16.0
		offs.append(m[0] * bx + m[2] * bz - x0)
		offs.append(m[3] * bx + m[5] * bz - y0)
		offs.append(m[6] * bx + m[8] * bz - zref)
		offs.append(float(nquads * 4))
		var mf: PackedFloat32Array = mesh["f"]
		for qi in mesh["trans"]:
			var zs := 0.0
			for v in 4:
				var o: int = (qi * 4 + v) * 8
				var mz: float = m[6] * (bx + mf[o]) + m[7] * mf[o + 1] + m[8] * (bz + mf[o + 2])
				zs += mz
			trans_keys.append(_f32_key(zs / 4.0, seq))
			trans_keys.append(nquads + qi)
			seq += 1
		vf.append_array(mf)
		vi.append_array(mesh["iv"])
		nquads += mesh["n"]
	timing["gather_ms"] += (Time.get_ticks_usec() - t0) / 1000.0
	timing["quads"] += nquads
	if probe.size() == 2:
		_probe_pixel(probe[0], probe[1], w, h, vf, vi, offs, chunks, nquads, zref)
	# sort translucent quads back to front (ascending map z), stable
	var keyed := PackedInt64Array()
	var pairs := trans_keys.size() / 2
	var order := PackedInt32Array()
	if pairs > 0:
		var ks := PackedInt64Array()
		ks.resize(pairs)
		var by_seq := PackedInt32Array()
		by_seq.resize(pairs)
		for i in pairs:
			ks[i] = trans_keys[i * 2]
			by_seq[i] = trans_keys[i * 2 + 1]
		ks.sort()
		order.resize(pairs)
		for i in pairs:
			order[i] = by_seq[ks[i] & 0x7FFFFFFF]
	var t1 := Time.get_ticks_usec()
	var img_bytes := _draw(w, h, vf, vi, offs, order, nquads, zhalf)
	timing["gpu_ms"] += (Time.get_ticks_usec() - t1) / 1000.0
	var full := Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, img_bytes)
	var tiles: Array[Image] = []
	for ty in nty:
		for tx in ntx:
			tiles.append(full.get_region(Rect2i(tx * TILE, (nty - 1 - ty) * TILE, TILE, TILE)))
	return tiles


## Debug: lists the quads covering pixel (px, py) (py from the top of the rendered image), nearest first.
func _probe_pixel(px: int, py: int, w: int, h: int, vf: PackedFloat32Array, vi: PackedInt32Array, offs: PackedFloat32Array, chunks: Array[Vector2i], nquads: int, zref: float) -> void:
	var m := persp.w2m
	var cx := px + 0.5
	var cy := h - (py + 0.5)
	var hits := []
	var nchunk := offs.size() / 4
	var ci := 0
	var picked: Array[Vector2i] = []
	for c in chunks:
		var mesh = _meshes.get(c)
		if mesh != null and mesh["n"] > 0:
			picked.append(c)
	for q in nquads:
		while ci + 1 < nchunk and int(offs[(ci + 1) * 4 + 3]) <= q * 4:
			ci += 1
		var pts := []
		for v in 4:
			var o := (q * 4 + v) * 8
			var x: float = vf[o]
			var y: float = vf[o + 1]
			var z: float = vf[o + 2]
			pts.append([m[0] * x + m[1] * y + m[2] * z + offs[ci * 4], m[3] * x + m[4] * y + m[5] * z + offs[ci * 4 + 1], m[6] * x + m[7] * y + m[8] * z + offs[ci * 4 + 2]])
		for tri in [[0, 1, 2], [0, 2, 3]]:
			var a: Array = pts[tri[0]]
			var b: Array = pts[tri[1]]
			var c: Array = pts[tri[2]]
			var det: float = (b[1] - c[1]) * (a[0] - c[0]) + (c[0] - b[0]) * (a[1] - c[1])
			if absf(det) < 1e-9:
				continue
			var l1: float = ((b[1] - c[1]) * (cx - c[0]) + (c[0] - b[0]) * (cy - c[1])) / det
			var l2: float = ((c[1] - a[1]) * (cx - c[0]) + (a[0] - c[0]) * (cy - c[1])) / det
			var l3 := 1.0 - l1 - l2
			if l1 >= 0.0 and l2 >= 0.0 and l3 >= 0.0:
				hits.append([l1 * a[2] + l2 * b[2] + l3 * c[2], q, ci])
	hits.sort_custom(func(p, r): return p[0] > r[0])
	print("probe pixel %d,%d: %d quads cover it" % [px, py, hits.size()])
	for k in mini(hits.size(), 6):
		var q: int = hits[k][1]
		var tf := vi[q * 12]
		var o := q * 4 * 8
		var cc: Vector2i = picked[hits[k][2]] if hits[k][2] < picked.size() else Vector2i.ZERO
		var tn := reg.tex_names[tf & 0xFFFF]
		print("  z=%.4f quad %d chunk %s block %d,%d,%d tex=%s cls=%d yeven=%d noshade=%d color=%06x light=%05x uv0=(%.3f,%.3f)" % [hits[k][0], q, cc, int(vf[o]), int(vf[o + 1]), int(vf[o + 2]), tn, (tf >> 16) & 7, (tf >> 19) & 1, (tf >> 20) & 1, vi[q * 12 + 1], vi[q * 12 + 2], vf[o + 3], vf[o + 4]])


func _draw(w: int, h: int, vf: PackedFloat32Array, vi: PackedInt32Array, offs: PackedFloat32Array, order: PackedInt32Array, nquads: int, zhalf: float) -> PackedByteArray:
	var fbd := _get_fb(w, h)
	var u := PackedFloat32Array()
	var mm := persp.w2m
	u.append_array(PackedFloat32Array([mm[0], mm[1], mm[2], 0.0, mm[3], mm[4], mm[5], 0.0, mm[6], mm[7], mm[8], 0.0]))
	u.append_array(PackedFloat32Array([float(w), float(h), -zhalf, zhalf]))
	var ui := PackedInt32Array([persp.scale, ATLAS_COLS, offs.size() / 4, 0])
	ui.append_array(_shadow)
	var ubytes := u.to_byte_array()
	ubytes.append_array(ui.to_byte_array())
	var ubuf := rd.uniform_buffer_create(ubytes.size(), ubytes)
	var b_vf := _storage(vf.to_byte_array())
	var b_vi := _storage(vi.to_byte_array())
	var b_off := _storage(offs.to_byte_array())
	var b_order := _storage(order.to_byte_array())
	var uset := rd.uniform_set_create([
		_u(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 0, [ubuf]),
		_u(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [_sampler, _atlas]),
		_u(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 2, [b_vf]),
		_u(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 3, [b_vi]),
		_u(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 4, [b_off]),
		_u(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 5, [b_order]),
	], _shader, 0)
	var out_buf := rd.storage_buffer_create(w * h * 4)
	var fin_set := rd.uniform_set_create([
		_u(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, [_sampler, fbd["color"]]),
		_u(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 1, [out_buf]),
	], _finish_shader, 0)
	var dl := rd.draw_list_begin(fbd["fb"], RenderingDevice.DRAW_CLEAR_COLOR_ALL | RenderingDevice.DRAW_CLEAR_DEPTH, PackedColorArray([Color(0, 0, 0, 0)]), 0.0)
	if nquads > 0:
		rd.draw_list_bind_uniform_set(dl, uset, 0)
		rd.draw_list_bind_render_pipeline(dl, _pipe_opaque)
		rd.draw_list_draw(dl, false, 1, nquads * 6)
		if order.size() > 0:
			rd.draw_list_bind_render_pipeline(dl, _pipe_trans)
			rd.draw_list_draw(dl, false, 1, order.size() * 6)
	rd.draw_list_end()
	var pc := PackedInt32Array([w, h, 0, 0]).to_byte_array()
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, _finish_pipe)
	rd.compute_list_bind_uniform_set(cl, fin_set, 0)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, ceili(w / 8.0), ceili(h / 8.0), 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	var bytes := rd.buffer_get_data(out_buf)
	for r in [fin_set, uset, out_buf, b_order, b_off, b_vi, b_vf, ubuf]:
		rd.free_rid(r)
	return bytes


func _u(type: int, binding: int, ids: Array) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = type
	u.binding = binding
	for id in ids:
		u.add_id(id)
	return u
