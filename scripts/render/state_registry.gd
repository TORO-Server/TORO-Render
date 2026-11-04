class_name StateRegistry
extends RefCounted
## Block state registry: interns palette entries and bakes their models into quads on demand.
## Model resolution + baking and state classification.
## Data comes from `main.gd build-data` (data/assets, textures.bin/json, block_defaults.json).

const DOWN := 0
const UP := 1
const NORTH := 2
const SOUTH := 3
const WEST := 4
const EAST := 5
const NO_DIR := -1

const FLUID_NONE := 0
const FLUID_WATER := 1
const FLUID_LAVA := 2

const TINT_NONE := 0
const TINT_GRASS := 1
const TINT_FOLIAGE := 2
const TINT_WATER := 3
const TINT_FIXED := 0x1000000

const DIR_VEC := [Vector3(0, -1, 0), Vector3(0, 1, 0), Vector3(0, 0, -1), Vector3(0, 0, 1), Vector3(-1, 0, 0), Vector3(1, 0, 0)]
const DIR_NAMES := {"down": 0, "up": 1, "north": 2, "south": 3, "west": 4, "east": 5}

var data_dir := ""
var tex_names := PackedStringArray()
var tex_index := {}
## per texture: 1 when every texel of the 16x16 sprite is fully opaque
var tex_opaque := PackedByteArray()
var tex_rgba := PackedByteArray()
var water_tex := 0
var lava_tex := 0

# per state
var s_name := PackedStringArray()
var s_air := PackedByteArray()
var s_opaque := PackedByteArray()      # opaque_cube
var s_solid := PackedByteArray()       # solid_tex
var s_fluid := PackedByteArray()
var s_level := PackedByteArray()
var s_waterlogged := PackedByteArray()
var s_cull_same := PackedByteArray()
var s_tint := PackedInt32Array()
var s_block := PackedInt32Array()
## quads per state: pos 4*3 + uv 4*2 floats = 20 per quad; meta 5 ints per quad (tex, tint, cull, normal, shade)
var s_qpos: Array = []
var s_qmeta: Array = []

var _lookup := {}
var _block_ids := {"air": 0}
var _defaults := {}
var _model_cache := {}
var _blockstates := {}
var unknown := {}


func load_dir(dir: String) -> bool:
	data_dir = dir
	var names_f := FileAccess.open(dir.path_join("textures.json"), FileAccess.READ)
	if names_f == null:
		push_error("missing %s/textures.json - run `main.gd build-data`" % dir)
		return false
	tex_names = PackedStringArray(JSON.parse_string(names_f.get_as_text()))
	for i in tex_names.size():
		tex_index[tex_names[i]] = i
	tex_rgba = FileAccess.get_file_as_bytes(dir.path_join("textures.bin"))
	var n := tex_names.size()
	tex_opaque.resize(n)
	for t in n:
		var op := 1
		for p in 256:
			if tex_rgba[t * 1024 + p * 4 + 3] != 255:
				op = 0
				break
		tex_opaque[t] = op
	var df := FileAccess.open(dir.path_join("block_defaults.json"), FileAccess.READ)
	if df != null:
		_defaults = JSON.parse_string(df.get_as_text())
	else:
		push_warning("block_defaults.json missing; default block properties unavailable")
	water_tex = tex_id("block/water_still")
	lava_tex = tex_id("block/lava_still")
	_add_state("minecraft:air", true)
	_lookup["minecraft:air"] = 0
	return true


## Flat tables for shaders/mesh_chunks.glsl: per state 8 uints (flags, tint, block, fluid level, first quad, quad count, 0, 0),
## quads as 20 floats (pos 4x3, uv 4x2) + 4 ints (tex, tint index, cull, normal). Rebuild when state_count() grows.
func gpu_tables() -> Dictionary:
	var si := PackedInt32Array()
	var qf := PackedFloat32Array()
	var qm := PackedInt32Array()
	var qn := 0
	for s in s_name.size():
		var flags: int = s_air[s] | (s_opaque[s] << 1) | (s_solid[s] << 2) | (s_fluid[s] << 3) | (s_waterlogged[s] << 5) | (s_cull_same[s] << 6)
		var meta: PackedInt32Array = s_qmeta[s]
		var n := meta.size() / 5
		si.append_array(PackedInt32Array([flags, s_tint[s], s_block[s], s_level[s], qn, n, 0, 0]))
		qf.append_array(s_qpos[s])
		for q in n:
			qm.append(meta[q * 5])
			qm.append(meta[q * 5 + 1])
			qm.append(meta[q * 5 + 2])
			qm.append(meta[q * 5 + 3])
		qn += n
	if qf.is_empty():
		qf.resize(20)
		qm.resize(4)
	return {"sinfo": si.to_byte_array(), "qf": qf.to_byte_array(), "qm": qm.to_byte_array(), "count": s_name.size()}


func tex_id(name_: String) -> int:
	var key := _strip_ns(name_)
	return tex_index.get(key, 0)


static func _strip_ns(s: String) -> String:
	return s.substr(10) if s.begins_with("minecraft:") else s


func state_count() -> int:
	return s_name.size()


func _add_state(full_name: String, is_air: bool) -> int:
	s_name.append(full_name)
	s_air.append(1 if is_air else 0)
	s_opaque.append(0)
	s_solid.append(0)
	s_fluid.append(0)
	s_level.append(0)
	s_waterlogged.append(0)
	s_cull_same.append(0)
	s_tint.append(0)
	s_block.append(0)
	s_qpos.append(PackedFloat32Array())
	s_qmeta.append(PackedInt32Array())
	return s_name.size() - 1


## props: Dictionary of String -> String/bool/number (palette Properties). Returns the state id.
func intern(block_name: String, given: Dictionary) -> int:
	var props := {}
	var d = _defaults.get(block_name)
	if d != null:
		for k in d:
			props[k] = d[k]
	for k in given:
		var v = given[k]
		props[k] = v if v is String else (("true" if v else "false") if v is bool else str(v))
	var keys := props.keys()
	keys.sort()
	var key := block_name
	var first := true
	for k in keys:
		key += ("[" if first else ",") + k + "=" + props[k]
		first = false
	var id = _lookup.get(key)
	if id != null:
		return id
	var sid := _build(block_name, props)
	_lookup[key] = sid
	return sid


func _block_id(n: String) -> int:
	if not _block_ids.has(n):
		_block_ids[n] = _block_ids.size()
	return _block_ids[n]


static func _alias(n: String) -> String:
	match n:
		"chain":
			return "iron_chain"
		"grass":
			return "short_grass"
		"cave_air", "void_air":
			return "air"
		"flowing_water":
			return "water"
		"flowing_lava":
			return "lava"
	return ""


static func _tint_for(n: String) -> int:
	match n:
		"grass_block", "short_grass", "tall_grass", "fern", "large_fern", "sugar_cane", "potted_fern":
			return TINT_GRASS
		"oak_leaves", "jungle_leaves", "acacia_leaves", "dark_oak_leaves", "vine", "mangrove_leaves":
			return TINT_FOLIAGE
		"birch_leaves":
			return TINT_FIXED | 0x80a755
		"spruce_leaves":
			return TINT_FIXED | 0x619961
		"lily_pad":
			return TINT_FIXED | 0x208030
		"water", "bubble_column", "water_cauldron":
			return TINT_WATER
	return TINT_NONE


func _read_json(rel: String) -> Variant:
	var f := FileAccess.open(data_dir.path_join("assets").path_join(rel), FileAccess.READ)
	if f == null:
		return null
	return JSON.parse_string(f.get_as_text())


func _build(full_name: String, props: Dictionary) -> int:
	var n := _strip_ns(full_name)
	if n == "air" or n == "cave_air" or n == "void_air":
		return _add_state(full_name, true)
	var a := _alias(n)
	if a != "" and not FileAccess.file_exists(data_dir.path_join("assets/blockstates/%s.json" % n)):
		n = a
	var block := _block_id(n)
	var waterlogged: bool = props.get("waterlogged", "false") == "true" or n in ["kelp", "kelp_plant", "seagrass", "tall_seagrass", "bubble_column"]
	var sid := _add_state(full_name, false)
	s_block[sid] = block
	s_tint[sid] = _tint_for(n)
	s_waterlogged[sid] = 1 if waterlogged else 0
	s_solid[sid] = 1
	if n == "water" or n == "lava":
		s_fluid[sid] = FLUID_WATER if n == "water" else FLUID_LAVA
		s_level[sid] = int(props.get("level", "0")) if str(props.get("level", "0")).is_valid_int() else 0
		s_cull_same[sid] = 1
		s_solid[sid] = 0
		return sid
	var def = _blockstates.get(n, 0)
	if typeof(def) == TYPE_INT:
		var j = _read_json("blockstates/%s.json" % n)
		def = _parse_blockstate(j) if j != null else null
		_blockstates[n] = def
	if def == null:
		unknown[n] = unknown.get(n, 0) + 1
		s_air[sid] = 1
		s_solid[sid] = 0
		s_tint[sid] = 0
		s_waterlogged[sid] = 0
		s_block[sid] = 0
		return sid
	var qpos := PackedFloat32Array()
	var qmeta := PackedInt32Array()
	for vr in _select_variants(def, props):
		var m = _resolve_model(vr["model"])
		if m != null and not (m["elements"] as Array).is_empty():
			_bake(m, vr["x"], vr["y"], qpos, qmeta)
	var nq := qmeta.size() / 5
	var all_opaque := true
	for q in nq:
		if tex_opaque[qmeta[q * 5]] == 0:
			all_opaque = false
			break
	var opaque_cube := _is_full_cube(qpos, qmeta)
	var is_leaves := n.ends_with("_leaves")
	s_solid[sid] = 1 if ((all_opaque or opaque_cube) and not is_leaves and nq > 0) else 0
	s_opaque[sid] = 1 if (opaque_cube and not is_leaves) else 0
	s_cull_same[sid] = 1 if (n in ["glass", "tinted_glass", "ice", "frosted_ice", "slime_block", "honey_block", "packed_ice"] or n.ends_with("_stained_glass")) else 0
	s_qpos[sid] = qpos
	s_qmeta[sid] = qmeta
	return sid


func _is_full_cube(qpos: PackedFloat32Array, qmeta: PackedInt32Array) -> bool:
	var seen := [false, false, false, false, false, false]
	for q in qmeta.size() / 5:
		var c := qmeta[q * 5 + 2]
		if c < 0 or tex_opaque[qmeta[q * 5]] == 0:
			continue
		var lo := [1.0, 1.0, 1.0]
		var hi := [0.0, 0.0, 0.0]
		for v in 4:
			for i in 3:
				var p := qpos[q * 20 + v * 3 + i]
				lo[i] = minf(lo[i], p)
				hi[i] = maxf(hi[i], p)
		var ax := 1 if (c == DOWN or c == UP) else (2 if (c == NORTH or c == SOUTH) else 0)
		var full := true
		for i in 3:
			if i != ax and not (lo[i] <= 0.001 and hi[i] >= 0.999):
				full = false
		if full:
			seen[c] = true
	return not seen.has(false)


# ---------------------------------------------------------------------------------------------
# Models

func _resolve_model(name_: String) -> Variant:
	var key := _strip_ns(name_)
	if _model_cache.has(key):
		return _model_cache[key]
	var r = _resolve_uncached(key, 0)
	_model_cache[key] = r
	return r


## Rounds to float32. Baking is done with float32 operations (as Dynmap's Java code does) so that tie-breaks on
## 45-degree rotated quads (normal class East/West vs North/South) come out the same way.
static var _f32 := PackedFloat32Array([0.0])


static func _r(x: float) -> float:
	_f32[0] = x
	return _f32[0]


func _f3(v: Variant) -> Variant:
	if v is Array and v.size() >= 3:
		return [_r(float(v[0])), _r(float(v[1])), _r(float(v[2]))]
	return null


func _resolve_uncached(key: String, depth: int) -> Variant:
	if depth > 16:
		return null
	var json = _read_json("models/%s.json" % key)
	if json == null or not json is Dictionary:
		return null
	var m := {"textures": {}, "elements": []}
	var parent = json.get("parent")
	if parent is String and not parent.begins_with("builtin/") and not parent.contains("builtin/"):
		var pm = _resolve_uncached(_strip_ns(parent), depth + 1)
		if pm != null:
			m["textures"] = (pm["textures"] as Dictionary).duplicate()
			m["elements"] = pm["elements"]
	var tx = json.get("textures")
	if tx is Dictionary:
		for k in tx:
			var v = tx[k]
			var s = null
			if v is String:
				s = v
			elif v is Dictionary and v.get("sprite") is String:
				s = v["sprite"]
			if s != null:
				m["textures"][k] = s
	var els = json.get("elements")
	if els is Array:
		var out := []
		for e in els:
			if not e is Dictionary:
				continue
			var from = _f3(e.get("from"))
			var to = _f3(e.get("to"))
			if from == null or to == null:
				continue
			var rot = null
			var r = e.get("rotation")
			if r is Dictionary and r.get("axis") is String and (r["axis"] as String).length() > 0 and r.get("angle") != null:
				var origin = _f3(r.get("origin"))
				rot = [(r["axis"] as String)[0], _r(float(r["angle"])), origin if origin != null else [8.0, 8.0, 8.0], bool(r.get("rescale", false))]
			var faces := []
			var fs = e.get("faces")
			if fs is Dictionary:
				# serde_json maps iterate in sorted key order, which fixes the draw order of coplanar quads
				var fk: Array = fs.keys()
				fk.sort()
				for dname in fk:
					if not DIR_NAMES.has(dname):
						continue
					var f = fs[dname]
					var uv = null
					var ua = f.get("uv")
					if ua is Array and ua.size() == 4:
						uv = [_r(float(ua[0])), _r(float(ua[1])), _r(float(ua[2])), _r(float(ua[3]))]
					var cull := NO_DIR
					var cf = f.get("cullface")
					if cf is String and DIR_NAMES.has(cf):
						cull = DIR_NAMES[cf]
					faces.append([DIR_NAMES[dname], {
						"uv": uv, "texture": str(f.get("texture", "")), "cull": cull,
						"rotation": int(f.get("rotation", 0)), "tint": int(f.get("tintindex", -1))}])
			out.append({"from": from, "to": to, "rot": rot, "shade": bool(e.get("shade", true)), "faces": faces})
		m["elements"] = out
	return m


## null when a #variable is unresolved (the face is skipped); an empty name is a real result (missing texture).
func _resolve_texref(textures: Dictionary, r_: String) -> Variant:
	var r := r_
	for _i in 16:
		if r.begins_with("#"):
			if not textures.has(r.substr(1)):
				return null
			r = textures[r.substr(1)]
		else:
			return r
	return null


static func _default_uv(d: int, f: Array, t: Array) -> Array:
	match d:
		DOWN:
			return [f[0], _r(16.0 - t[2]), t[0], _r(16.0 - f[2])]
		UP:
			return [f[0], f[2], t[0], t[2]]
		NORTH:
			return [_r(16.0 - t[0]), _r(16.0 - t[1]), _r(16.0 - f[0]), _r(16.0 - f[1])]
		SOUTH:
			return [f[0], _r(16.0 - t[1]), t[0], _r(16.0 - f[1])]
		WEST:
			return [f[2], _r(16.0 - t[1]), t[2], _r(16.0 - f[1])]
	return [_r(16.0 - t[2]), _r(16.0 - t[1]), _r(16.0 - f[2]), _r(16.0 - f[1])]


static func _face_verts(d: int, f: Array, t: Array) -> Array:
	var x0: float = f[0]
	var y0: float = f[1]
	var z0: float = f[2]
	var x1: float = t[0]
	var y1: float = t[1]
	var z1: float = t[2]
	match d:
		DOWN:
			return [[x0, y0, z1], [x0, y0, z0], [x1, y0, z0], [x1, y0, z1]]
		UP:
			return [[x0, y1, z0], [x0, y1, z1], [x1, y1, z1], [x1, y1, z0]]
		NORTH:
			return [[x1, y1, z0], [x1, y0, z0], [x0, y0, z0], [x0, y1, z0]]
		SOUTH:
			return [[x0, y1, z1], [x0, y0, z1], [x1, y0, z1], [x1, y1, z1]]
		WEST:
			return [[x0, y1, z0], [x0, y0, z0], [x0, y0, z1], [x0, y1, z1]]
	return [[x1, y1, z1], [x1, y0, z1], [x1, y0, z0], [x1, y1, z0]]


static func _rotate_point(p: Array, axis: String, deg: float, origin: Array, rescale: bool) -> Array:
	var r := _r(deg * 0.017453292)  # f32::to_radians
	var s := _r(sin(r))
	var c := _r(cos(r))
	var v := [_r(p[0] - origin[0]), _r(p[1] - origin[1]), _r(p[2] - origin[2])]
	var ia := 2
	var ib := 0
	var k := 1
	if axis == "x":
		ia = 1
		ib = 2
		k = 0
	elif axis != "y":
		ia = 0
		ib = 1
		k = 2
	var va: float = v[ia]
	var vb: float = v[ib]
	v[ia] = _r(_r(va * c) - _r(vb * s))
	v[ib] = _r(_r(va * s) + _r(vb * c))
	if rescale:
		var sc := _r(1.0 / maxf(absf(c), 1e-6))
		for i in 3:
			if i != k:
				v[i] = _r(v[i] * sc)
	return [_r(v[0] + origin[0]), _r(v[1] + origin[1]), _r(v[2] + origin[2])]


## x rotation: (dy, dz) -> (dz, -dy)
static func _rot_x90(v: Array) -> Array:
	return [v[0], v[2], -v[1]]


## y rotation, clockwise seen from above: (dx, dz) -> (-dz, dx)
static func _rot_y90(v: Array) -> Array:
	return [-v[2], v[1], v[0]]


static func _dir_from_vec(v: Array) -> int:
	var ax := absf(v[0])
	var ay := absf(v[1])
	var az := absf(v[2])
	if ay >= ax and ay >= az:
		return UP if v[1] >= 0.0 else DOWN
	if ax >= az:
		return EAST if v[0] >= 0.0 else WEST
	return SOUTH if v[2] >= 0.0 else NORTH


func _bake(model: Dictionary, rx: int, ry: int, qpos: PackedFloat32Array, qmeta: PackedInt32Array) -> void:
	var nx := ((rx / 90) % 4 + 4) % 4
	var ny := ((ry / 90) % 4 + 4) % 4
	var textures: Dictionary = model["textures"]
	for el in model["elements"]:
		for df in el["faces"]:
			var d: int = df[0]
			var face: Dictionary = df[1]
			var tname = _resolve_texref(textures, face["texture"])
			if tname == null:
				continue
			var tid := tex_id(tname)
			var verts := _face_verts(d, el["from"], el["to"])
			var rot = el["rot"]
			if rot != null:
				for i in 4:
					verts[i] = _rotate_point(verts[i], rot[0], rot[1], rot[2], rot[3])
			var uv = face["uv"]
			if uv == null:
				uv = _default_uv(d, el["from"], el["to"])
			var u0: float = uv[0]
			var v0: float = uv[1]
			var u1: float = uv[2]
			var v1: float = uv[3]
			var base := [[u0, v0], [u0, v1], [u1, v1], [u1, v0]]
			var shift: int = ((face["rotation"] / 90) % 4 + 4) % 4
			var uvs := []
			for i in 4:
				uvs.append(base[(i + shift) % 4])
			var cull: int = face["cull"]
			for _k in nx:
				for i in 4:
					var c := [_r(verts[i][0] - 8.0), _r(verts[i][1] - 8.0), _r(verts[i][2] - 8.0)]
					var r := _rot_x90(c)
					verts[i] = [_r(r[0] + 8.0), _r(r[1] + 8.0), _r(r[2] + 8.0)]
				if cull >= 0:
					var cv: Vector3 = DIR_VEC[cull]
					cull = _dir_from_vec(_rot_x90([cv.x, cv.y, cv.z]))
			for _k in ny:
				for i in 4:
					var c := [_r(verts[i][0] - 8.0), _r(verts[i][1] - 8.0), _r(verts[i][2] - 8.0)]
					var r := _rot_y90(c)
					verts[i] = [_r(r[0] + 8.0), _r(r[1] + 8.0), _r(r[2] + 8.0)]
				if cull >= 0:
					var cv: Vector3 = DIR_VEC[cull]
					cull = _dir_from_vec(_rot_y90([cv.x, cv.y, cv.z]))
			var e1 := [_r(verts[1][0] - verts[0][0]), _r(verts[1][1] - verts[0][1]), _r(verts[1][2] - verts[0][2])]
			var e2 := [_r(verts[2][0] - verts[0][0]), _r(verts[2][1] - verts[0][1]), _r(verts[2][2] - verts[0][2])]
			var nrm := [
				_r(_r(e1[1] * e2[2]) - _r(e1[2] * e2[1])),
				_r(_r(e1[2] * e2[0]) - _r(e1[0] * e2[2])),
				_r(_r(e1[0] * e2[1]) - _r(e1[1] * e2[0]))]
			var normal := _dir_from_vec(nrm)
			for i in 4:
				qpos.append(verts[i][0] / 16.0)
				qpos.append(verts[i][1] / 16.0)
				qpos.append(verts[i][2] / 16.0)
			for i in 4:
				qpos.append(uvs[i][0] / 16.0)
				qpos.append(uvs[i][1] / 16.0)
			qmeta.append(tid)
			qmeta.append(face["tint"])
			qmeta.append(cull)
			qmeta.append(normal)
			qmeta.append(1 if el["shade"] else 0)


# ---------------------------------------------------------------------------------------------
# Blockstates

func _parse_variant(v: Variant) -> Variant:
	if v is Array:
		if v.is_empty():
			return null
		v = v[0]
	if not v is Dictionary or not v.get("model") is String:
		return null
	return {"model": v["model"], "x": int(v.get("x", 0)), "y": int(v.get("y", 0)), "uvlock": bool(v.get("uvlock", false))}


func _parse_cond(v: Variant) -> Variant:
	if not v is Dictionary:
		return null
	if v.get("OR") is Array:
		var l := []
		for c in v["OR"]:
			var pc = _parse_cond(c)
			if pc != null:
				l.append(pc)
		return {"or": l}
	if v.get("AND") is Array:
		var l2 := []
		for c in v["AND"]:
			var pc2 = _parse_cond(c)
			if pc2 != null:
				l2.append(pc2)
		return {"and": l2}
	var props := []
	for k in v:
		var val = v[k]
		var s := ""
		if val is String:
			s = val
		elif val is bool:
			s = "true" if val else "false"
		elif val is float or val is int:
			s = str(int(val)) if float(val) == floorf(float(val)) else str(val)
		else:
			continue
		props.append([k, Array(s.split("|"))])
	return {"props": props}


func _parse_blockstate(j: Variant) -> Variant:
	if not j is Dictionary:
		return null
	if j.get("variants") is Dictionary:
		var out := []
		# serde_json iterates variant keys sorted; the first matching one wins
		var keys: Array = j["variants"].keys()
		keys.sort()
		for k in keys:
			var props := []
			for p in (k as String).split(","):
				if p == "":
					continue
				var kv := p.split("=", true, 1)
				if kv.size() == 2:
					props.append([kv[0], kv[1]])
			var vr = _parse_variant(j["variants"][k])
			if vr != null:
				out.append([props, vr])
		return {"variants": out}
	if j.get("multipart") is Array:
		var parts := []
		for part in j["multipart"]:
			var apply = _parse_variant(part.get("apply"))
			if apply == null:
				continue
			var when = _parse_cond(part["when"]) if part.has("when") else null
			parts.append({"when": when, "apply": apply})
		return {"multipart": parts}
	return null


func _cond_matches(c: Dictionary, props: Dictionary) -> bool:
	if c.has("or"):
		for x in c["or"]:
			if _cond_matches(x, props):
				return true
		return false
	if c.has("and"):
		for x in c["and"]:
			if not _cond_matches(x, props):
				return false
		return true
	for pv in c["props"]:
		if not props.has(pv[0]) or not (props[pv[0]] in pv[1]):
			return false
	return true


func _select_variants(def: Dictionary, props: Dictionary) -> Array:
	if def.has("variants"):
		for entry in def["variants"]:
			var ok := true
			for kv in entry[0]:
				if not props.has(kv[0]) or props[kv[0]] != kv[1]:
					ok = false
					break
			if ok:
				return [entry[1]]
		return []
	var out := []
	for part in def["multipart"]:
		if part["when"] == null or _cond_matches(part["when"], props):
			out.append(part["apply"])
	return out
