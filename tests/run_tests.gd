extends SceneTree
## Checks of everything that needs no GPU: file parsers, config handling, queue bookkeeping. From the repository root:
##   godot --headless --path . --import
##   godot --headless --path . -s tests/run_tests.gd
## Feeding bad input is the point, so warnings and errors about rejected data in the output are expected.

const TMP := "user://tests"

var _checks := 0
var _fails := 0


class Longs:
	var raw: PackedByteArray

	func _init(raw_: PackedByteArray) -> void:
		raw = raw_


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(TMP)
	_test_nbt()
	_test_region()
	_test_chunk()
	_test_gpu_pack()
	_test_scan()
	_test_jar()
	_test_registry()
	_test_config()
	_test_live_feed()
	_test_watch_queue()
	_test_dirty_feed()
	_test_watch_flood()
	print("%d checks, %d failed" % [_checks, _fails])
	quit(1 if _fails > 0 else 0)


func _eq(name: String, got: Variant, want: Variant) -> void:
	_checks += 1
	if typeof(got) != typeof(want) or got != want:
		_fails += 1
		print("FAIL %s: got %s, wanted %s" % [name, got, want])


func _ok(name: String, condition: bool) -> void:
	_eq(name, condition, true)


func _write(path: String, bytes: PackedByteArray) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()


func _write_text(path: String, text: String) -> void:
	_write(path, text.to_utf8_buffer())


# --- writers ---------------------------------------------------------------------------------------------------------


func _be() -> StreamPeerBuffer:
	var sp := StreamPeerBuffer.new()
	sp.big_endian = true
	return sp


func _tag_of(v: Variant) -> int:
	if v is Dictionary:
		return Nbt.T_COMPOUND
	if v is Array:
		return Nbt.T_LIST
	if v is String:
		return Nbt.T_STRING
	if v is int:
		return Nbt.T_INT
	if v is PackedByteArray:
		return Nbt.T_BYTE_ARRAY
	if v is Longs:
		return Nbt.T_LONG_ARRAY
	return Nbt.T_END


func _put_string(sp: StreamPeerBuffer, s: String) -> void:
	var b := s.to_utf8_buffer()
	sp.put_u16(b.size())
	sp.put_data(b)


func _put_value(sp: StreamPeerBuffer, v: Variant) -> void:
	if v is Dictionary:
		for k: String in v:
			sp.put_u8(_tag_of(v[k]))
			_put_string(sp, k)
			_put_value(sp, v[k])
		sp.put_u8(Nbt.T_END)
	elif v is Array:
		sp.put_u8(_tag_of(v[0]) if not v.is_empty() else Nbt.T_END)
		sp.put_32(v.size())
		for e in v:
			_put_value(sp, e)
	elif v is String:
		_put_string(sp, v)
	elif v is int:
		sp.put_32(v)
	elif v is PackedByteArray:
		sp.put_32(v.size())
		sp.put_data(v)
	elif v is Longs:
		sp.put_32(v.raw.size() / 8)
		sp.put_data(v.raw)


func _nbt(root: Dictionary) -> PackedByteArray:
	var sp := _be()
	sp.put_u8(Nbt.T_COMPOUND)
	sp.put_u16(0)
	_put_value(sp, root)
	return sp.data_array


## A root compound whose only entry `v` has the given tag and raw payload (for payloads _put_value would not write).
func _nbt_raw(tag: int, payload: PackedByteArray) -> PackedByteArray:
	var sp := _be()
	sp.put_u8(Nbt.T_COMPOUND)
	sp.put_u16(0)
	sp.put_u8(tag)
	_put_string(sp, "v")
	sp.put_data(payload)
	sp.put_u8(Nbt.T_END)
	return sp.data_array


func _i32(v: int) -> PackedByteArray:
	var sp := _be()
	sp.put_32(v)
	return sp.data_array


## Section with `bits`-bit block data whose first entry is `first` (the array has the length the format requires).
func _section(y: int, names: Array, first := 0) -> Dictionary:
	var palette := []
	for n in names:
		palette.append({"Name": n})
	var states := {"palette": palette}
	if names.size() > 1:
		var bits := ChunkData._bits_for(names.size(), 4)
		var raw := PackedByteArray()
		raw.resize(ChunkData._packed_bytes(4096, bits))
		raw.fill(0)
		raw[7] = first  # lowest bits of the first long, big endian
		states["data"] = Longs.new(raw)
	return {"Y": y, "block_states": states, "biomes": {"palette": ["minecraft:plains"]}}


func _chunk_nbt(sections: Variant) -> PackedByteArray:
	return _nbt({"Status": "minecraft:full", "sections": sections})


# --- NBT -------------------------------------------------------------------------------------------------------------


func _test_nbt() -> void:
	var longs := PackedByteArray()
	longs.resize(16)
	var v := Nbt.parse(_nbt({"a": 5, "s": "text", "l": [1, 2], "e": [], "c": {"x": PackedByteArray([1, 2])}, "n": Longs.new(longs)}))
	_eq("nbt int", v.get("a"), 5)
	_eq("nbt string", v.get("s"), "text")
	_eq("nbt list", v.get("l"), [1, 2])
	_eq("nbt empty list", v.get("e"), [])
	_eq("nbt nested byte array", v.get("c", {}).get("x"), PackedByteArray([1, 2]))
	_eq("nbt long array keeps raw bytes", v.get("n"), longs)

	var huge := 0x7FFFFFFF
	_eq("byte array longer than the data", Nbt.parse(_nbt_raw(Nbt.T_BYTE_ARRAY, _i32(huge))), {})
	_eq("byte array of negative length", Nbt.parse(_nbt_raw(Nbt.T_BYTE_ARRAY, _i32(-1))), {})
	_eq("int array longer than the data", Nbt.parse(_nbt_raw(Nbt.T_INT_ARRAY, _i32(huge))), {})
	_eq("long array longer than the data", Nbt.parse(_nbt_raw(Nbt.T_LONG_ARRAY, _i32(huge))), {})
	var list_of_ints := PackedByteArray([Nbt.T_INT])
	list_of_ints.append_array(_i32(huge))
	_eq("list longer than the data", Nbt.parse(_nbt_raw(Nbt.T_LIST, list_of_ints)), {})
	var list_of_end := PackedByteArray([Nbt.T_END])
	list_of_end.append_array(_i32(3))
	_eq("non-empty list of the end tag", Nbt.parse(_nbt_raw(Nbt.T_LIST, list_of_end)), {})
	var list_bad_type := PackedByteArray([200])
	list_bad_type.append_array(_i32(1))
	_eq("list of an unknown tag", Nbt.parse(_nbt_raw(Nbt.T_LIST, list_bad_type)), {})
	var negative_list := PackedByteArray([Nbt.T_INT])
	negative_list.append_array(_i32(-1))
	_eq("negative list length means empty", Nbt.parse(_nbt_raw(Nbt.T_LIST, negative_list)).get("v"), [])
	_eq("string longer than the data", Nbt.parse(_nbt_raw(Nbt.T_STRING, PackedByteArray([0xFF, 0xFF]))), {})
	_eq("unknown tag", Nbt.parse(_nbt_raw(99, PackedByteArray())), {})

	var truncated := _nbt({"a": 5})
	truncated.resize(truncated.size() - 1)
	_eq("compound without an end tag", Nbt.parse(truncated), {})
	_eq("not a compound", Nbt.parse(PackedByteArray([Nbt.T_INT, 0, 0, 0, 0, 0, 0])), {})
	_eq("empty input", Nbt.parse(PackedByteArray()), {})

	_ok("nesting within the limit", not Nbt.parse(_deep(Nbt.MAX_DEPTH - 2)).is_empty())
	_eq("nesting past the limit", Nbt.parse(_deep(Nbt.MAX_DEPTH + 5)), {})

	var many := PackedByteArray([Nbt.T_BYTE])
	many.append_array(_i32(Nbt.MAX_VALUES + 1))
	var body := PackedByteArray()
	body.resize(Nbt.MAX_VALUES + 1)
	many.append_array(body)
	_eq("too many values", Nbt.parse(_nbt_raw(Nbt.T_LIST, many)), {})


func _deep(levels: int) -> PackedByteArray:
	var sp := _be()
	sp.put_u8(Nbt.T_COMPOUND)
	sp.put_u16(0)
	for _i in levels:
		sp.put_u8(Nbt.T_COMPOUND)
		_put_string(sp, "a")
	for _i in levels + 1:
		sp.put_u8(Nbt.T_END)
	return sp.data_array


# --- region files ----------------------------------------------------------------------------------------------------


func _region_with(sector: int, length: int, comp: int, body: PackedByteArray) -> PackedByteArray:
	var rg := PackedByteArray()
	rg.resize(8192)
	rg.fill(0)
	rg[0] = (sector >> 16) & 0xFF
	rg[1] = (sector >> 8) & 0xFF
	rg[2] = sector & 0xFF
	rg[3] = 1
	var sp := _be()
	sp.put_32(length)
	sp.put_u8(comp)
	sp.put_data(body)
	rg.append_array(sp.data_array)
	return rg


func _test_region() -> void:
	var nbt := _nbt({"a": 1})
	var deflated := nbt.compress(FileAccess.COMPRESSION_DEFLATE)
	var gz := nbt.compress(FileAccess.COMPRESSION_GZIP)
	_eq("deflate chunk", WorldReader.raw_chunk(_region_with(2, deflated.size() + 1, 2, deflated), 0, 0), nbt)
	_eq("gzip chunk", WorldReader.raw_chunk(_region_with(2, gz.size() + 1, 1, gz), 0, 0), nbt)
	_eq("uncompressed chunk", WorldReader.raw_chunk(_region_with(2, nbt.size() + 1, 3, nbt), 0, 0), nbt)
	_eq("absent chunk", WorldReader.raw_chunk(_region_with(2, nbt.size() + 1, 3, nbt), 1, 0), PackedByteArray())
	_eq("too short for a header", WorldReader.raw_chunk(PackedByteArray([1, 2, 3]), 0, 0), PackedByteArray())
	_eq("offset inside the header", WorldReader.raw_chunk(_region_with(1, nbt.size() + 1, 3, nbt), 0, 0), PackedByteArray())
	_eq("offset past the file", WorldReader.raw_chunk(_region_with(9999, nbt.size() + 1, 3, nbt), 0, 0), PackedByteArray())
	_eq("length past the file", WorldReader.raw_chunk(_region_with(2, 0x7FFFFFF0, 3, nbt), 0, 0), PackedByteArray())
	_eq("only a compression byte (external file)", WorldReader.raw_chunk(_region_with(2, 1, 0x82, PackedByteArray()), 0, 0), PackedByteArray())
	_eq("unknown compression", WorldReader.raw_chunk(_region_with(2, nbt.size() + 1, 77, nbt), 0, 0), PackedByteArray())

	var big := PackedByteArray()
	big.resize(WorldReader.MAX_CHUNK_BYTES + 4096)
	big.fill(0)
	var bomb := big.compress(FileAccess.COMPRESSION_DEFLATE)
	big = PackedByteArray()
	_eq("output larger than the limit", WorldReader.raw_chunk(_region_with(2, bomb.size() + 1, 2, bomb), 0, 0), PackedByteArray())

	_eq("region name", WorldReader.region_coords("r.-1.2.mca"), [-1, 2])
	for bad in ["r.1.mca", "x.1.2.mca", "r.a.2.mca", "r.1.2.mcc", "r.999999.0.mca", "r.0.-99999999999999999999.mca"]:
		_eq("region name " + bad, WorldReader.region_coords(bad), [])
	var p := TMP.path_join("r.0.0.mca")
	_write(p, PackedByteArray([1, 2, 3]))
	_eq("read region file", WorldReader.read_region(p), PackedByteArray([1, 2, 3]))
	_eq("missing region file", WorldReader.read_region(TMP.path_join("none.mca")), PackedByteArray())


# --- chunks ----------------------------------------------------------------------------------------------------------


func _data_dir() -> String:
	var d := TMP.path_join("data")
	DirAccess.make_dir_recursive_absolute(d.path_join("assets/blockstates"))
	DirAccess.make_dir_recursive_absolute(d.path_join("assets/models/block"))
	_write_text(d.path_join("textures.json"), '["missingno","block/water_still","block/lava_still"]')
	var tex := PackedByteArray()
	tex.resize(3 * 1024)
	tex.fill(255)
	_write(d.path_join("textures.bin"), tex)
	_write_text(d.path_join("block_defaults.json"), "{}")
	for n in ["stone", "dirt"]:
		_write_text(d.path_join("assets/blockstates/%s.json" % n), '{"variants":{"":{"model":"minecraft:block/%s"}}}' % n)
		_write_text(d.path_join("assets/models/block/%s.json" % n), "{}")
	# outside assets/: a palette entry must not be able to reach this
	_write_text(d.path_join("outside.json"), '{"variants":{"":{"model":"minecraft:block/stone"}}}')
	return d


func _registry() -> StateRegistry:
	var reg := StateRegistry.new()
	reg.load_dir(_data_dir())
	return reg


func _decode(sections: Variant, reg: StateRegistry) -> ChunkData:
	return ChunkData.decode(_chunk_nbt(sections), 0, 0, BlockTable.new(), reg)


func _test_chunk() -> void:
	var reg := _registry()
	var c := _decode([_section(0, ["minecraft:air", "minecraft:stone"], 1), _section(1, ["minecraft:dirt"])], reg)
	_ok("valid chunk decodes", c != null)
	if c != null:
		var stone := reg.intern("minecraft:stone", {})
		var dirt := reg.intern("minecraft:dirt", {})
		_eq("first block from the palette", c.block(0, 0, 0), stone)
		_eq("other blocks", c.block(1, 0, 0), 0)
		_eq("uniform section", c.block(5, 20, 5), dirt)
		_eq("above the sections", c.block(0, 100, 0), 0)

	var past := _decode([_section(0, ["minecraft:air", "minecraft:stone"], 15)], reg)
	_ok("index past the palette still decodes", past != null)
	if past != null:
		_eq("index past the palette reads as air", past.block(0, 0, 0), 0)

	_eq("Y out of range", _decode([_section(ChunkData.MAX_SECTION_Y + 1, ["minecraft:stone"])], reg), null)
	_eq("Y far out of range", _decode([_section(1 << 30, ["minecraft:stone"])], reg), null)
	_eq("the most negative Y", ChunkData.valid_section_y(-9223372036854775807 - 1), false)
	_eq("Y at the limit", ChunkData.valid_section_y(-ChunkData.MAX_SECTION_Y), true)
	_eq("sections not a list", _decode({"Y": 0}, reg), null)
	_eq("section not a compound", _decode([1, 2], reg), null)
	_eq("section without Y", _decode([{"block_states": {}}], reg), null)
	_eq("Y not a number", _decode([{"Y": "zero"}], reg), null)
	_eq("palette not a list", _decode([{"Y": 0, "block_states": {"palette": 1}}], reg), null)
	_eq("states not a compound", _decode([{"Y": 0, "block_states": 1}], reg), null)

	var short_data := _section(0, ["minecraft:air", "minecraft:stone"])
	var raw: PackedByteArray = short_data["block_states"]["data"].raw
	raw.resize(raw.size() - 8)
	short_data["block_states"]["data"] = Longs.new(raw)
	_eq("block data too short", _decode([short_data], reg), null)
	var data_as_bytes := _section(0, ["minecraft:air", "minecraft:stone"])
	data_as_bytes["block_states"]["data"] = 7
	_eq("block data not an array", _decode([data_as_bytes], reg), null)

	var wide := []
	for i in ChunkData.MAX_BLOCK_PALETTE + 1:
		wide.append({"Name": "minecraft:stone"})
	_eq("block palette too large", _decode([{"Y": 0, "block_states": {"palette": wide}}], reg), null)

	var sec := _section(0, ["minecraft:stone"])
	var biome_raw := PackedByteArray()
	biome_raw.resize(8)
	biome_raw.fill(0)
	sec["biomes"] = {"palette": ["minecraft:plains", "minecraft:desert"], "data": Longs.new(biome_raw)}
	_ok("biome data decodes", _decode([sec], reg) != null)
	var bad_biome := _section(0, ["minecraft:stone"])
	var three := PackedByteArray()
	three.resize(8)
	three.fill(0)
	three[7] = 3  # 2 bits for a palette of 3: index 3 is past it
	bad_biome["biomes"] = {"palette": ["minecraft:plains", "minecraft:desert", "minecraft:forest"], "data": Longs.new(three)}
	_eq("biome index past the palette", _decode([bad_biome], reg), null)
	var long_biome := _section(0, ["minecraft:stone"])
	long_biome["biomes"] = {"palette": ["minecraft:plains", "minecraft:desert"], "data": Longs.new(PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))}
	_eq("biome data of the wrong size", _decode([long_biome], reg), null)


func _test_gpu_pack() -> void:
	var reg := _registry()
	var c := _decode([_section(0, ["minecraft:air", "minecraft:stone", "minecraft:dirt"])], reg)
	var world := WorldReader.new("", BlockTable.new())
	world._chunks[Vector2i(0, 0)] = c
	var chunks: Array[Vector2i] = [Vector2i(0, 0)]
	var packed := GpuWorld.pack_set(world, chunks)
	var pal: PackedInt32Array = packed["pal"].to_int32_array()
	_eq("palette padded to every index the data can hold", pal.size(), 16)
	_eq("palette entries kept", pal[1], reg.intern("minecraft:stone", {}))
	_eq("padding reads as air", pal[15], 0)
	_eq("block data as long as the shader indexes", packed["data"].size(), 2048)


func _test_scan() -> void:
	var dir := TMP.path_join("scan")
	DirAccess.make_dir_recursive_absolute(dir)
	var nbt := _chunk_nbt([_section(0, ["minecraft:stone"]), _section(1 << 30, ["minecraft:stone"]), _section(2, ["minecraft:air"])])
	var deflated := nbt.compress(FileAccess.COMPRESSION_DEFLATE)
	_write(dir.path_join("r.0.0.mca"), _region_with(2, deflated.size() + 1, 2, deflated))
	_write(dir.path_join("r.999999.0.mca"), _region_with(2, deflated.size() + 1, 2, deflated))
	var scan := ScanCache.build(ProjectSettings.globalize_path(dir))
	_eq("scan keeps only region files inside the world border", scan.count(), 1)
	_eq("scan ignores a section outside the Y range", [scan.min_y(), scan.max_y()], [0, 16])


# --- build-data's jar reader -----------------------------------------------------------------------------------------


## entries: [name, stored bytes, optional declared size, optional method]
func _zip(entries: Array, cd_offset_delta := 0) -> PackedByteArray:
	var body := StreamPeerBuffer.new()
	var cd := StreamPeerBuffer.new()
	for e in entries:
		var name: PackedByteArray = (e[0] as String).to_utf8_buffer()
		var data: PackedByteArray = e[1]
		var declared: int = e[2] if e.size() > 2 else data.size()
		var method: int = e[3] if e.size() > 3 else 0
		var at := body.get_position()
		body.put_u32(0x04034B50)
		for v in [20, 0, method, 0, 0]:
			body.put_u16(v)
		body.put_u32(0)  # crc
		body.put_u32(data.size())
		body.put_u32(declared)
		body.put_u16(name.size())
		body.put_u16(0)
		body.put_data(name)
		body.put_data(data)
		cd.put_u32(0x02014B50)
		for v in [20, 20, 0, method, 0, 0]:
			cd.put_u16(v)
		cd.put_u32(0)
		cd.put_u32(data.size())
		cd.put_u32(declared)
		cd.put_u16(name.size())
		for v in [0, 0, 0, 0]:
			cd.put_u16(v)
		cd.put_u32(0)
		cd.put_u32(at)
		cd.put_data(name)
	var out := StreamPeerBuffer.new()
	out.put_data(body.data_array)
	out.put_data(cd.data_array)
	out.put_u32(0x06054B50)
	out.put_u16(0)
	out.put_u16(0)
	out.put_u16(entries.size())
	out.put_u16(entries.size())
	out.put_u32(cd.get_size())
	out.put_u32(body.get_size() + cd_offset_delta)
	out.put_u16(0)
	return out.data_array


func _open_jar(bytes: PackedByteArray) -> JarReader:
	var p := TMP.path_join("t.jar")
	_write(p, bytes)
	var j := JarReader.new()
	return j if j.open(p) else null


func _test_jar() -> void:
	var text := "{}".to_utf8_buffer()
	var j := _open_jar(_zip([
		["assets/minecraft/blockstates/a.json", text],
		["assets/minecraft/blockstates/../../../../evil.json", text],
		["../evil.json", text],
		["/abs.json", text],
		["c:/abs.json", text],
		["a\\..\\evil.json", text],
		["big.json", text, JarReader.MAX_ENTRY_BYTES + 1, 8],
	]))
	_ok("jar opens", j != null)
	if j != null:
		_eq("only safe names are indexed", Array(j.names()).filter(func(n: String) -> bool: return n != "big.json"), ["assets/minecraft/blockstates/a.json"])
		_eq("stored entry", j.read("assets/minecraft/blockstates/a.json"), text)
		_eq("declared size over the limit", j.read("big.json"), PackedByteArray())
		_eq("unknown entry", j.read("nope"), PackedByteArray())
	_eq("central directory past the file", _open_jar(_zip([["a", text]], 1 << 20)), null)
	_eq("not an archive", _open_jar("not a zip file, long enough to search for a directory".to_utf8_buffer()), null)
	# the central record of one entry: 46 bytes and its name, in front of the 22 bytes of the end record
	var cut := _zip([["a.json", text]])
	var record := cut.size() - 22 - 46 - "a.json".length()
	cut[record + 28] = 0xFF  # name length: reaches past the file
	cut[record + 29] = 0xFF
	_eq("entry name past the file", _open_jar(cut), null)
	var oob := _zip([["a.json", text]])
	oob[record + 42] = 0xFF  # local header offset: past the file
	oob[record + 43] = 0xFF
	var jo := _open_jar(oob)
	_ok("jar with a bad local offset opens", jo != null)
	if jo != null:
		_eq("local header past the file", jo.read("a.json"), PackedByteArray())

	var zp := TMP.path_join("real.jar")
	var packer := ZIPPacker.new()
	packer.open(zp)
	packer.start_file("assets/minecraft/blockstates/b.json")
	packer.write_file('{"variants":{}}'.to_utf8_buffer())
	packer.close_file()
	packer.close()
	var real := JarReader.new()
	_ok("zip from another writer opens", real.open(zp))
	_eq("deflated entry", real.read("assets/minecraft/blockstates/b.json"), '{"variants":{}}'.to_utf8_buffer())


# --- block states ----------------------------------------------------------------------------------------------------


func _test_registry() -> void:
	var reg := _registry()
	_ok("known block", reg.intern("minecraft:stone", {}) > 0)
	_eq("same state, same id", reg.intern("minecraft:stone", {}), reg.intern("minecraft:stone", {}))
	var before := reg.state_count()
	_eq("name leaving the data directory", reg.intern("minecraft:../../outside", {}), 0)
	_eq("name with a separator trick", reg.intern("minecraft:a/../../outside", {}), 0)
	_eq("name with odd characters", reg.intern("minecraft:Stone Block", {}), 0)
	_eq("name too long", reg.intern("minecraft:" + "a".repeat(200), {}), 0)
	var props := {}
	for i in StateRegistry.MAX_PROPERTIES + 1:
		props["p%d" % i] = "1"
	_eq("too many properties", reg.intern("minecraft:stone", props), 0)
	_eq("property value too long", reg.intern("minecraft:stone", {"p": "a".repeat(100)}), 0)
	_eq("rejected entries add no states", reg.state_count(), before)
	_ok("rejected entries are counted", reg.rejected > 0)
	var unknown := reg.intern("minecraft:not_in_the_data", {})
	_ok("unknown block is its own state", unknown > 0)
	_eq("unknown block draws nothing", reg.s_air[unknown], 1)
	reg.max_states = reg.state_count()
	_eq("limit on the number of states", reg.intern("minecraft:another_block", {}), 0)
	_eq("existing states still resolve", reg.intern("minecraft:not_in_the_data", {}), unknown)


# --- database settings -----------------------------------------------------------------------------------------------


func _args(words: Array) -> Args:
	return Args.parse(PackedStringArray(words))


func _test_config() -> void:
	OS.unset_environment("DYNMAP_DB_PASSWORD")
	OS.unset_environment("DYNMAP_DB_PASSWORD_FILE")
	var cfg := {"db": {"host": "tidb", "port": 4000, "user": "renderer", "database": "dynmap"}}
	var db := MapDef.db_config(_args(["run"]), cfg)
	_eq("host from the config", db.get("host"), "tidb")
	_eq("user from the config", db.get("user"), "renderer")
	_ok("no password configured", not db.has("password"))
	_eq("the config is not modified", cfg["db"].has("password"), false)

	var over := MapDef.db_config(_args(["run", "--db-host", "h", "--db-port", "5", "--db-user", "u"]), cfg)
	_eq("options override the config", [over.get("host"), over.get("port"), over.get("user")], ["h", 5, "u"])
	_ok("no password option", not MapDef.db_config(_args(["run", "--db-password", "x"]), cfg).has("password"))
	_ok("password text in the config is ignored", not MapDef.db_config(_args(["run"]), {"db": {"password": "x"}}).has("password"))

	var pf := TMP.path_join("db_password")
	_write_text(pf, "from-file\n")
	var with_file := {"db": {"user": "renderer", "password_file": pf}}
	_eq("password from the config's file", MapDef.db_config(_args(["run"]), with_file).get("password"), "from-file")
	OS.set_environment("DYNMAP_DB_PASSWORD_FILE", pf)
	_eq("password from the file in the environment", MapDef.db_config(_args(["run"]), cfg).get("password"), "from-file")
	OS.set_environment("DYNMAP_DB_PASSWORD", "from-env")
	_eq("the variable wins", MapDef.db_config(_args(["run"]), with_file).get("password"), "from-env")
	OS.unset_environment("DYNMAP_DB_PASSWORD")
	OS.unset_environment("DYNMAP_DB_PASSWORD_FILE")

	var missing := MapDef.db_config(_args(["run"]), {"db": {"user": "renderer", "password_file": TMP.path_join("none")}})
	_ok("unreadable password file is an error", missing.has("error"))
	var store := TileStore.new()
	store.configure(missing)
	_eq("no connection without the password", store.connect_db(), false)
	_ok("the store reports why", store.error.contains("password file"))
	var nobody := TileStore.new()
	nobody.configure({"host": "tidb"})
	_eq("no connection without a user", nobody.connect_db(), false)
	_ok("the store asks for a user", nobody.error.contains("user"))


# --- live feed -------------------------------------------------------------------------------------------------------


func _test_live_feed() -> void:
	_ok("wss", LiveFeed.allowed_url("wss://map.example.net/up/ws"))
	_ok("ws to this machine", LiveFeed.allowed_url("ws://127.0.0.1:3000/up/ws"))
	_eq("ws to another host", LiveFeed.allowed_url("ws://map.example.net/up/ws"), false)
	_eq("ws with a look-alike host", LiveFeed.allowed_url("ws://127.0.0.1.example.net/up/ws"), false)
	_eq("other scheme", LiveFeed.allowed_url("http://map.example.net/up/ws"), false)
	var feed := LiveFeed.new("ws://map.example.net/up/ws")
	feed.watch("main")
	_eq("insecure feed follows nothing", feed.healthy(), false)

	var good := {"x": 1.5, "y": 64, "z": -2.0}
	_eq("players with coordinates", LiveFeed.valid_players([good, {"x": 1}, {"x": "1", "y": 2, "z": 3}, "text", 5, null, {"x": INF, "y": 0, "z": 0}]), [good])
	var crowd := []
	for i in LiveFeed.MAX_PLAYERS + 10:
		crowd.append(good)
	_eq("limit on players", LiveFeed.valid_players(crowd).size(), LiveFeed.MAX_PLAYERS)

	var ok_feed := LiveFeed.new("wss://map.example.net/up/ws")
	var w := {"players": []}
	ok_feed._message(w, '{"type":"players","players":[{"x":1,"y":2,"z":3},{"x":"a"}]}')
	_eq("message keeps valid players", w["players"].size(), 1)
	ok_feed._message(w, '{"type":5,"players":[]}')
	_eq("message of another type", w["players"].size(), 1)
	ok_feed._message(w, "not json")
	_eq("message that is not JSON", w["players"].size(), 1)


# --- resident updater's queue ----------------------------------------------------------------------------------------


func _test_watch_queue() -> void:
	var state := TMP.path_join("state")
	DirAccess.make_dir_recursive_absolute(state)
	DirAccess.remove_absolute(state.path_join("watch-7.json"))  # from an earlier run of these checks
	var def := MapDef.new()
	def.id = 7
	var job := WatchJob.new()
	_ok("map added", job.add(def, state))
	var ms: WatchJob.MapState = job.maps[0]
	var a := Vector2i(1, 1)
	var b := Vector2i(2, 2)
	var c := Vector2i(3, 3)
	var order := [a, b, c]
	for m in order:
		ms.pending[m] = 100.0
	var first := job._next_group(ms, order)
	_eq("a batch without failures", first.size(), order.size())
	ms.attempts[b] = 1
	var alone := job._next_group(ms, order)
	_eq("a tile the process died on goes alone", alone.size(), 1)
	_eq("which one", alone[0], b)

	job._save(ms)
	var again := WatchJob.new()
	_ok("map added from the saved state", again.add(def, state))
	var ms2: WatchJob.MapState = again.maps[0]
	_eq("pending survives a restart", ms2.pending.size(), 3)
	_eq("the count survives a restart", ms2.attempts.get(b, 0), 1)

	ms2.attempts[b] = WatchJob.MAX_ATTEMPTS - 1
	again._drop_failing(ms2)
	_ok("below the limit it stays", ms2.pending.has(b))
	ms2.attempts[b] = WatchJob.MAX_ATTEMPTS
	again._drop_failing(ms2)
	_eq("at the limit it is dropped", ms2.pending.has(b), false)
	_eq("the others stay", ms2.pending.size(), 2)
	_eq("no count left", ms2.attempts.is_empty(), true)


# --- dirty feed (block-change events) ----------------------------------------------------------------------------


func _test_dirty_feed() -> void:
	var msg = JSON.parse_string('{"t":"dirty","worlds":{"main":{"bukkit":[[1,2],[3,4]],"worldedit":[[3,4],[5,6]]},"nether":{"bukkit":"junk"}}}')
	var parsed := DirtyFeed.parse_dirty(msg)
	_eq("worlds parsed", parsed.keys(), ["main"])
	_eq("chunks of both sources merged", parsed["main"].size(), 3)
	_ok("chunk kept", parsed["main"].has(Vector2i(5, 6)))
	_eq("bad message", DirtyFeed.parse_dirty({"t": "dirty"}), {})
	_eq("bad entries dropped", DirtyFeed.parse_dirty({"worlds": {"w": {"bukkit": [["1", 2], [1, 2, 3], [7, 8]]}}}), {"w": [Vector2i(7, 8)]})

	var feed := DirtyFeed.new()
	feed._token = "secret"
	var c := {"peer": WebSocketPeer.new(), "authed": false, "deadline": 0}
	feed._message(c, '{"t":"dirty","worlds":{"main":{"bukkit":[[0,0]]}}}')
	_eq("dirty before auth is dropped", feed.queued(), 0)
	feed._message(c, '{"t":"auth","token":"wrong"}')
	_eq("wrong token does not authenticate", c["authed"], false)
	feed._message(c, '{"t":"auth","token":"secret"}')
	_eq("token authenticates", c["authed"], true)
	feed._message(c, '{"t":"dirty","worlds":{"main":{"bukkit":[[0,0],[1,1]]}}}')
	_eq("dirty after auth is queued", feed.queued(), 2)
	var drained := feed.drain()
	_eq("drained world", drained.keys(), ["main"])
	_eq("queue empty after drain", feed.queued(), 0)


# --- flood control of the resident updater -----------------------------------------------------------------------


func _test_watch_flood() -> void:
	var state := TMP.path_join("state")
	DirAccess.make_dir_recursive_absolute(state)
	DirAccess.remove_absolute(state.path_join("watch-8.json"))
	var def := MapDef.new()
	def.id = 8
	def.world = "main"
	var job := WatchJob.new()
	_ok("map added", job.add(def, state))
	var ms: WatchJob.MapState = job.maps[0]
	var now := 10_000.0

	# merging events: first queued time wins, repeats add heat, the Anvil scan adds none
	var chunks: Array[Vector2i] = [Vector2i(0, 0)]
	var offered := job._offer(ms, chunks, now, true)
	_ok("megas offered", offered > 0)
	_eq("pending matches the offer", ms.pending.size(), offered)
	var mega: Vector2i = ms.pending.keys()[0]
	_eq("offered again adds nothing new", job._offer(ms, chunks, now + 50.0, true), 0)
	_eq("first queued time kept", ms.pending[mega], now)
	_eq("heat counted", int(ms.heat.get(mega, 0)), 1)
	job._offer(ms, chunks, now + 60.0, false)
	_eq("the scan adds no heat", int(ms.heat.get(mega, 0)), 1)

	# cooldown: a mega inside its cooldown is skipped, a stale one is not
	ms.pending.clear()
	ms.heat.clear()
	var a := Vector2i(10, 10)
	var b := Vector2i(11, 10)
	ms.pending[a] = now
	ms.pending[b] = now
	ms.cooldown_until[a] = now + 100.0
	_eq("cooldown skips", job._next_group(ms, [a, b], now), [b])
	ms.pending[a] = now - job.stale_after - 1.0
	_eq("stale beats cooldown", job._next_group(ms, [a, b], now), [a, b])
	ms.cooldown_until.clear()

	# reserved seat: the oldest queued mega leads the batch even when it ranks last
	ms.pending.clear()
	var x := Vector2i(20, 20)
	var y := Vector2i(21, 20)
	var z := Vector2i(22, 20)
	ms.pending[x] = now - 10.0
	ms.pending[y] = now - 300.0
	ms.pending[z] = now - 100.0
	var group := job._next_group(ms, [x, y, z], now)
	_eq("oldest leads the batch", group[0], y)
	_eq("everybody fits", group.size(), 3)

	# hot cap: with two seats, at most one hot mega rides along
	var small := WatchJob.new()
	small.max_megas = 2
	_ok("map added", small.add(def, state))
	var sms: WatchJob.MapState = small.maps[0]
	var h1 := Vector2i(30, 30)
	var h2 := Vector2i(31, 30)
	var n1 := Vector2i(32, 30)
	for m in [h1, h2, n1]:
		sms.pending[m] = now
	sms.heat[h1] = WatchJob.HOT_HEAT + 2
	sms.heat[h2] = WatchJob.HOT_HEAT + 2
	_eq("hot cap leaves the second hot one out", small._next_group(sms, [h1, h2, n1], now), [h1, n1])

	# bbox order: row by row, nothing dropped
	ms.pending.clear()
	var p := Vector2i(5, 9)
	var q := Vector2i(7, 8)
	var r := Vector2i(6, 8)
	for m in [p, q, r]:
		ms.pending[m] = now
	_eq("bbox works in row order", job._next_group_bbox(ms, now), [r, q, p])
	_eq("bbox is the extent", job._pending_bbox(ms), [Vector2i(5, 8), Vector2i(7, 9)])

	# cooldown and heat survive a restart
	ms.cooldown_until[p] = now + 240.0
	ms.heat[q] = 4
	job._save(ms)
	var again := WatchJob.new()
	_ok("map added from the saved state", again.add(def, state))
	var ms2: WatchJob.MapState = again.maps[0]
	_eq("cooldown survives a restart", float(ms2.cooldown_until.get(p, 0.0)), now + 240.0)
	_eq("heat survives a restart", int(ms2.heat.get(q, 0)), 4)
