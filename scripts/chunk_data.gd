class_name ChunkData
extends RefCounted
## One decoded chunk (1.18+ palette layout, 26.x quirks). Section block data is unpacked lazily.

var cx := 0
var cz := 0
var min_sec := 0
var max_sec := 0
var sky_fill := 0
## sec_y - min_sec -> Section (see below), or null
var sections: Array = []
var table: BlockTable
var biome_names := PackedStringArray()


class Section:
	extends RefCounted
	var uniform := 0
	var pal := PackedInt32Array()      # palette index -> block id
	var raw_data := PackedByteArray()  # big-endian longs, empty when the section is uniform
	var bits := 0
	var blocks := PackedInt32Array()   # lazily unpacked palette indices
	var sky := PackedByteArray()
	var blk := PackedByteArray()
	var biome_pal := PackedInt32Array()
	var biome_data := PackedInt32Array()  # 64 palette indices, empty = uniform
	var biome_uniform := 0

	func block(lx: int, ly: int, lz: int) -> int:
		if raw_data.is_empty():
			return uniform
		if blocks.is_empty():
			blocks = Nbt.unpack(Nbt.longs(raw_data), bits, 4096)
		return pal[blocks[(ly << 8) | (lz << 4) | lx]]


static func _palette_entry(v: Variant) -> Dictionary:
	# 26.x writes {"": name} for plain states and {"id": name, "properties": {...}}; older worlds use Name/Properties
	var name := "minecraft:air"
	var props := {}
	if v is String:
		name = v
	elif v is Dictionary:
		for k in ["Name", "name", "id", ""]:
			if v.has(k) and v[k] is String:
				name = v[k]
				break
		for k in ["Properties", "properties"]:
			if v.has(k) and v[k] is Dictionary:
				props = v[k]
	return {"name": name, "props": props}


static func _bits_for(n: int, minimum: int) -> int:
	var b := 0
	while (1 << b) < n:
		b += 1
	return maxi(b, minimum)


static func decode(raw: PackedByteArray, cx_: int, cz_: int, tbl: BlockTable) -> ChunkData:
	var root := Nbt.parse(raw)
	if root.is_empty():
		return null
	var status = root.get("Status", "minecraft:full")
	if status is String and status != "minecraft:full" and status != "full":
		return null
	var secs: Array = root.get("sections", [])
	if secs.is_empty():
		return null
	var c := ChunkData.new()
	c.cx = cx_
	c.cz = cz_
	c.table = tbl
	var lo := 1000
	var hi := -1000
	for s in secs:
		var y: int = s["Y"]
		lo = mini(lo, y)
		hi = maxi(hi, y)
	c.min_sec = lo
	c.max_sec = hi
	c.sections.resize(hi - lo + 1)
	var top_sky := lo
	for s in secs:
		var sec := Section.new()
		var y: int = s["Y"]
		var bs: Dictionary = s.get("block_states", {})
		var palette: Array = bs.get("palette", [])
		sec.pal.resize(palette.size())
		for i in palette.size():
			var e := _palette_entry(palette[i])
			var id := tbl.id_of(e["name"])
			# waterlogged blocks and other non-solid blocks inside water read as water from above
			if tbl.kind[id] != BlockTable.KIND_FLUID and e["props"].get("waterlogged", "false") in ["true", true, 1]:
				if tbl.kind[id] == BlockTable.KIND_NONE:
					id = tbl.water_id
			sec.pal[i] = id
		if palette.size() <= 1 or not bs.has("data"):
			sec.uniform = sec.pal[0] if sec.pal.size() > 0 else 0
		else:
			sec.raw_data = bs["data"]
			sec.bits = _bits_for(palette.size(), 4)
		var bio: Dictionary = s.get("biomes", {})
		var bpal: Array = bio.get("palette", [])
		sec.biome_pal.resize(bpal.size())
		for i in bpal.size():
			sec.biome_pal[i] = tbl.biome_id(_palette_entry(bpal[i])["name"])
		if bpal.size() > 1 and bio.has("data"):
			sec.biome_data = Nbt.unpack(Nbt.longs(bio["data"]), _bits_for(bpal.size(), 1), 64)
		else:
			sec.biome_uniform = sec.biome_pal[0] if sec.biome_pal.size() > 0 else 0
		if s.has("SkyLight") and (s["SkyLight"] as PackedByteArray).size() == 2048:
			sec.sky = s["SkyLight"]
			top_sky = maxi(top_sky, y + 1)
		if s.has("BlockLight") and (s["BlockLight"] as PackedByteArray).size() == 2048:
			sec.blk = s["BlockLight"]
		c.sections[y - lo] = sec
	c.sky_fill = top_sky
	return c


func min_y() -> int:
	return min_sec * 16


func max_y() -> int:
	return (max_sec + 1) * 16


func section_at(y: int) -> Section:
	var si := (y >> 4) - min_sec
	if si < 0 or si >= sections.size():
		return null
	return sections[si]


## Block id at chunk-local x,z and absolute y (0 = air outside).
func block(lx: int, y: int, lz: int) -> int:
	var s := section_at(y)
	if s == null:
		return 0
	return s.block(lx, y & 15, lz)


## max(sky, block) light level (15 above the chunk, 0 below).
func light(lx: int, y: int, lz: int) -> int:
	var s := section_at(y)
	if s == null:
		return 15 if y >= max_y() else 0
	var i := ((y & 15) << 8) | (lz << 4) | lx
	var sky := 0
	if not s.sky.is_empty():
		var b: int = s.sky[i >> 1]
		sky = (b >> 4) if (i & 1) == 1 else (b & 15)
	elif (y >> 4) >= sky_fill:
		sky = 15
	var bl := 0
	if not s.blk.is_empty():
		var b2: int = s.blk[i >> 1]
		bl = (b2 >> 4) if (i & 1) == 1 else (b2 & 15)
	return maxi(sky, bl)


func biome(lx: int, y: int, lz: int) -> int:
	var s := section_at(y)
	if s == null:
		return 0
	if s.biome_data.is_empty():
		return s.biome_uniform
	return s.biome_pal[s.biome_data[(((y & 15) >> 2) << 4) | ((lz >> 2) << 2) | (lx >> 2)]]
