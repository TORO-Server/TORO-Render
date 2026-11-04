class_name BlockTable
extends RefCounted
## Block-name lookup built by `main.gd build-data` (data/blocks.json, atlas.bin, biomes.json).

const KIND_NONE := 0
const KIND_SOLID := 1
const KIND_FLUID := 2

const TINT_NONE := 0
const TINT_GRASS := 1
const TINT_FOLIAGE := 2
const TINT_WATER := 3
const TINT_FIXED := 0x1000000

var names: PackedStringArray = []
var kind := PackedByteArray()
var tex := PackedInt32Array()
var tint := PackedInt32Array()
## per texture: true when all 16 texels of the 4x4 sprite are fully opaque
var tex_opaque := PackedByteArray()
var atlas := PackedByteArray()
var tex_count := 0
var water_id := 0
var biome_index := {}
var biome_grass := PackedInt32Array()
var biome_foliage := PackedInt32Array()
var biome_water := PackedInt32Array()
var _ids := {}
var unknown := {}


func load_dir(dir: String) -> bool:
	var f := FileAccess.open(dir.path_join("blocks.json"), FileAccess.READ)
	if f == null:
		push_error("missing %s/blocks.json - run `main.gd build-data`" % dir)
		return false
	var blocks: Dictionary = JSON.parse_string(f.get_as_text())
	atlas = FileAccess.get_file_as_bytes(dir.path_join("atlas.bin"))
	tex_count = atlas.size() / 64
	tex_opaque.resize(tex_count)
	for t in tex_count:
		var op := 1
		for i in 16:
			if atlas[t * 64 + i * 4 + 3] != 255:
				op = 0
				break
		tex_opaque[t] = op
	# id 0 = unknown/air
	names.append("minecraft:air")
	kind.append(0)
	tex.append(0)
	tint.append(0)
	_ids["minecraft:air"] = 0
	for n in blocks:
		var v: Array = blocks[n]
		_ids[n] = names.size()
		names.append(n)
		tex.append(int(v[0]))
		kind.append(int(v[1]))
		tint.append(int(v[2]))
	water_id = _ids["minecraft:water"]
	var bf := FileAccess.open(dir.path_join("biomes.json"), FileAccess.READ)
	var biomes: Dictionary = JSON.parse_string(bf.get_as_text())
	for n in biomes:
		biome_index[n] = biome_grass.size()
		biome_grass.append(int(biomes[n][0]))
		biome_foliage.append(int(biomes[n][1]))
		biome_water.append(int(biomes[n][2]))
	return true


## GPU lookup: grass, foliage, water colour per biome id.
func gpu_biome_colors() -> PackedByteArray:
	var a := PackedInt32Array()
	for i in biome_grass.size():
		a.append(biome_grass[i])
		a.append(biome_foliage[i])
		a.append(biome_water[i])
	return a.to_byte_array()


func id_of(block_name: String) -> int:
	var i = _ids.get(block_name)
	if i == null:
		unknown[block_name] = unknown.get(block_name, 0) + 1
		return 0
	return i


func biome_id(biome_name: String) -> int:
	return biome_index.get(biome_name, 0)


func tint_color(block_id: int, biome: int) -> int:
	var t := tint[block_id]
	if t == TINT_NONE:
		return 0xFFFFFF
	if t == TINT_GRASS:
		return biome_grass[biome] if biome < biome_grass.size() else 0xFFFFFF
	if t == TINT_FOLIAGE:
		return biome_foliage[biome] if biome < biome_foliage.size() else 0xFFFFFF
	if t == TINT_WATER:
		return biome_water[biome] if biome < biome_water.size() else 0x3F76E4
	return t & 0xFFFFFF
