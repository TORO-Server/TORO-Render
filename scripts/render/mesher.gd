class_name Mesher
extends RefCounted
## Chunk meshing: block states -> textured quads with Dynmap-style light samples (port of Dynmap-GPU mesh.rs).
## Reference implementation on the CPU; output layout matches what the raster pass consumes.
##
## Per quad, 4 vertices:
##   floats: pos.xyz (chunk-local x/z, absolute y), uv.xy, local.xyz     -> 8 floats per vertex
##   ints:   tex_flags, color, light                                     -> 3 ints per vertex

var reg: StateRegistry
var table: BlockTable
var topdown := false
## per texture: bit0 = has opaque texels, bit1 = has partially transparent texels (at the render scale)
var tex_class := PackedByteArray()
## indices (within the chunk) of quads that need the translucent pass
var trans := PackedInt32Array()
var _nb := []  # 3x3 ChunkData (null where missing), index (dz+1)*3 + (dx+1)
var f: PackedFloat32Array
var iv: PackedInt32Array

const DIRS := [[0, 0, -1, 0], [1, 0, 1, 0], [2, 0, 0, -1], [3, 0, 0, 1], [4, -1, 0, 0], [5, 1, 0, 0]]  # dir, dx, dy, dz
const NEI_SEMI := [[0, 1, 0], [-1, 0, 0], [1, 0, 0], [0, 0, -1], [0, 0, 1]]


func _init(r: StateRegistry, t: BlockTable) -> void:
	reg = r
	table = t


func _chunk(x: int, z: int) -> ChunkData:
	var dx := x >> 4
	var dz := z >> 4
	if dx < -1 or dx > 1 or dz < -1 or dz > 1:
		return null
	return _nb[(dz + 1) * 3 + dx + 1]


func _st(x: int, y: int, z: int) -> int:
	var c := _chunk(x, z)
	if c == null:
		return 0
	return c.block(x & 15, y, z & 15)


func _light(x: int, y: int, z: int) -> int:
	var c := _chunk(x, z)
	if c == null:
		return 15
	return c.light(x & 15, y, z & 15)


func _biome(x: int, y: int, z: int) -> int:
	var c := _chunk(x, z)
	if c == null:
		return 0
	return c.biome(x & 15, y, z & 15)


func _semi_light(x: int, y: int, z: int) -> int:
	var m := 0
	for d in NEI_SEMI:
		m = maxi(m, _light(x + d[0], y + d[1], z + d[2]))
	return m


## Light level for a block position as Dynmap samples it (see mesh.rs sample_light).
func _sample_light(sid: int, x: int, y: int, z: int, nv: Vector3i) -> int:
	if reg.s_fluid[sid] != 0:
		return _semi_light(x, y, z)
	if reg.s_air[sid] == 0 and reg.s_solid[sid] == 1:
		var ex := x + nv.x
		var ey := y + nv.y
		var ez := z + nv.z
		if reg.s_fluid[_st(ex, ey, ez)] != 0:
			return _semi_light(ex, ey, ez)
		return _light(ex, ey, ez)
	return _light(x, y, z)


## Light samples for a face with normal n: own | axis1- << 4 | axis1+ << 8 | axis2- << 12 | axis2+ << 16.
func _face_light(sid: int, x: int, y: int, z: int, n: int) -> int:
	var nvf: Vector3 = StateRegistry.DIR_VEC[n]
	var nv := Vector3i(int(nvf.x), int(nvf.y), int(nvf.z))
	var own := _sample_light(sid, x, y, z, nv)
	var a1: Vector3i
	var a2: Vector3i
	if n == StateRegistry.EAST or n == StateRegistry.WEST:
		a1 = Vector3i(0, 1, 0)
		a2 = Vector3i(0, 0, 1)
	elif n == StateRegistry.NORTH or n == StateRegistry.SOUTH:
		a1 = Vector3i(1, 0, 0)
		a2 = Vector3i(0, 1, 0)
	else:
		a1 = Vector3i(1, 0, 0)
		a2 = Vector3i(0, 0, 1)
	var r := own
	var shifts := [4, 8, 12, 16]
	var offs := [-a1, a1, -a2, a2]
	for i in 4:
		var p: Vector3i = Vector3i(x, y, z) + offs[i]
		r |= _sample_light(_st(p.x, p.y, p.z), p.x, p.y, p.z, nv) << shifts[i]
	return r


static func _shade_class(d: int) -> int:
	match d:
		StateRegistry.EAST, StateRegistry.WEST:
			return 1
		StateRegistry.NORTH, StateRegistry.SOUTH:
			return 2
		StateRegistry.UP:
			return 3
	return 4


func _tint_color(sid: int, x: int, y: int, z: int) -> int:
	var t := reg.s_tint[sid]
	if t == StateRegistry.TINT_NONE:
		return 0xFFFFFF
	if t >= StateRegistry.TINT_FIXED:
		return t & 0xFFFFFF
	var b := _biome(x, y, z)
	if t == StateRegistry.TINT_GRASS:
		return table.biome_grass[b] if b < table.biome_grass.size() else 0xFFFFFF
	if t == StateRegistry.TINT_FOLIAGE:
		return table.biome_foliage[b] if b < table.biome_foliage.size() else 0xFFFFFF
	return table.biome_water[b] if b < table.biome_water.size() else 0xFFFFFF


func _fluid_of(sid: int) -> int:
	if reg.s_fluid[sid] != 0:
		return reg.s_fluid[sid]
	return StateRegistry.FLUID_WATER if reg.s_waterlogged[sid] == 1 else 0


## nb: 9 chunks (row-major dz, dx), centre = nb[4]. Returns the number of quads; geometry is in `f` / `iv`.
func mesh_chunk(nb: Array) -> int:
	_nb = nb
	f = PackedFloat32Array()
	iv = PackedInt32Array()
	trans = PackedInt32Array()
	var center: ChunkData = nb[4]
	var tops := PackedInt32Array()
	tops.resize(256)
	tops.fill(-2147483648)
	if topdown:
		for z in 16:
			for x in 16:
				var y := center.max_y() - 1
				while y >= center.min_y():
					var id := center.block(x, y, z)
					if id != 0 and reg.s_opaque[id] == 1:
						tops[z * 16 + x] = y
						break
					y -= 1
	var nquads := 0
	for y in range(center.min_y(), center.max_y()):
		var sec := center.section_at(y)
		if sec == null or (sec.raw_data.is_empty() and sec.uniform == 0):
			continue
		var y_even := 1 if (y & 1) == 0 else 0
		for z in 16:
			for x in 16:
				var id := center.block(x, y, z)
				if id == 0 or y < tops[z * 16 + x]:
					continue
				if reg.s_air[id] == 1:
					continue
				if reg.s_opaque[id] == 1 and reg.s_fluid[id] == 0:
					var enclosed := true
					for d in DIRS:
						if reg.s_opaque[_st(x + d[1], y + d[2], z + d[3])] == 0:
							enclosed = false
							break
					if enclosed:
						continue
				if reg.s_fluid[id] == 0:
					var qp: PackedFloat32Array = reg.s_qpos[id]
					var qm: PackedInt32Array = reg.s_qmeta[id]
					for q in qm.size() / 5:
						var cull := qm[q * 5 + 2]
						if cull >= 0:
							var cv: Vector3 = StateRegistry.DIR_VEC[cull]
							var n := _st(x + int(cv.x), y + int(cv.y), z + int(cv.z))
							if reg.s_opaque[n] == 1 and reg.s_air[n] == 0:
								continue
							if reg.s_cull_same[id] == 1 and reg.s_block[n] == reg.s_block[id]:
								continue
						var color := _tint_color(id, x, y, z) if qm[q * 5 + 1] >= 0 else 0xFFFFFF
						var normal := qm[q * 5 + 3]
						var light := _face_light(id, x, y, z, normal)
						var flags := (qm[q * 5] & 0xFFFF) | (_shade_class(normal) << 16) | (y_even << 19)
						for v in 4:
							var o := q * 20 + v * 3
							f.append(x + qp[o])
							f.append(y + qp[o + 1])
							f.append(z + qp[o + 2])
							f.append(qp[q * 20 + 12 + v * 2])
							f.append(qp[q * 20 + 12 + v * 2 + 1])
							f.append(qp[o])
							f.append(qp[o + 1])
							f.append(qp[o + 2])
							iv.append(flags)
							iv.append(color)
							iv.append(light)
						_note_quad(qm[q * 5])
						nquads += 1
				var fl := reg.s_fluid[id]
				var level := reg.s_level[id]
				if fl == 0 and reg.s_waterlogged[id] == 1:
					fl = StateRegistry.FLUID_WATER
					level = 0
				if fl != 0:
					nquads += _emit_fluid(fl, level, x, y, z, y_even)
	return nquads


func _emit_fluid(fl: int, level: int, x: int, y: int, z: int, y_even: int) -> int:
	var fluid_above := _fluid_of(_st(x, y + 1, z)) == fl
	var h := 1.0 if (fluid_above or level >= 8) else float(8 - mini(level, 7)) / 9.0
	var tex := reg.water_tex if fl == StateRegistry.FLUID_WATER else reg.lava_tex
	var color := 0xFFFFFF
	if fl == StateRegistry.FLUID_WATER:
		var b := _biome(x, y, z)
		color = table.biome_water[b] if b < table.biome_water.size() else 0x3f76e4
	# stand-in state: a fluid block whose own light is the semi-transparent sample
	var stub := _fluid_stub(fl)
	var n := 0
	if not fluid_above:
		n += _fluid_quad([[0.0, h, 0.0], [0.0, h, 1.0], [1.0, h, 1.0], [1.0, h, 0.0]], 3, stub, tex, color, x, y, z, y_even)
	for d in DIRS:
		var dir: int = d[0]
		if dir == StateRegistry.UP or dir == StateRegistry.DOWN:
			continue
		var nid := _st(x + d[1], y, z + d[3])
		if _fluid_of(nid) == fl or (reg.s_opaque[nid] == 1 and reg.s_air[nid] == 0):
			continue
		var p: Array
		match dir:
			StateRegistry.NORTH:
				p = [[1.0, h, 0.0], [1.0, 0.0, 0.0], [0.0, 0.0, 0.0], [0.0, h, 0.0]]
			StateRegistry.SOUTH:
				p = [[0.0, h, 1.0], [0.0, 0.0, 1.0], [1.0, 0.0, 1.0], [1.0, h, 1.0]]
			StateRegistry.WEST:
				p = [[0.0, h, 0.0], [0.0, 0.0, 0.0], [0.0, 0.0, 1.0], [0.0, h, 1.0]]
			_:
				p = [[1.0, h, 1.0], [1.0, 0.0, 1.0], [1.0, 0.0, 0.0], [1.0, h, 0.0]]
		n += _fluid_quad(p, _shade_class(dir), stub, tex, color, x, y, z, y_even)
	return n


var _stub_cache := {}


## State id with fluid set and everything else default, used only to pick the fluid light-sampling branch.
func _fluid_stub(fl: int) -> int:
	if not _stub_cache.has(fl):
		var sid := reg._add_state("fluid_stub", false)
		reg.s_fluid[sid] = fl
		_stub_cache[fl] = sid
	return _stub_cache[fl]


func _fluid_quad(pos: Array, cls: int, stub: int, tex: int, color: int, x: int, y: int, z: int, y_even: int) -> int:
	var n_dir := StateRegistry.DOWN
	if cls == 1:
		n_dir = StateRegistry.EAST
	elif cls == 2:
		n_dir = StateRegistry.NORTH
	elif cls == 3:
		n_dir = StateRegistry.UP
	var light := _face_light(stub, x, y, z, n_dir)
	var uv := [[0.0, 0.0], [0.0, 1.0], [1.0, 1.0], [1.0, 0.0]]
	var flags := tex | (cls << 16) | (y_even << 19) | (1 << 20)
	for i in 4:
		f.append(x + pos[i][0])
		f.append(y + pos[i][1])
		f.append(z + pos[i][2])
		f.append(uv[i][0])
		f.append(uv[i][1])
		f.append(pos[i][0])
		f.append(pos[i][1])
		f.append(pos[i][2])
		iv.append(flags)
		iv.append(color)
		iv.append(light)
	_note_quad(tex)
	return 1


func _note_quad(tex: int) -> void:
	if tex < tex_class.size() and (tex_class[tex] & 2) != 0:
		trans.append(iv.size() / 12 - 1)
