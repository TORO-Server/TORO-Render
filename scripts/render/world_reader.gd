class_name WorldReader
extends RefCounted
## Reads Anvil region files: raw chunk NBT, decoded chunks (cached) and per-block lookups.


var region_dir := ""
var table: BlockTable
## chunks hold StateRegistry state ids
var registry: StateRegistry = null
var chunk_cache_limit := 512
var _regions := {}
var _chunks := {}
var stats := {"chunks": 0, "chunk_ms": 0.0}


func _init(dir: String, tbl: BlockTable) -> void:
	region_dir = dir
	table = tbl


func _region(rx: int, rz: int) -> PackedByteArray:
	var key := Vector2i(rx, rz)
	if _regions.has(key):
		return _regions[key]
	if _regions.size() >= 4:
		_regions.clear()
	var path := region_dir.path_join("r.%d.%d.mca" % [rx, rz])
	var data := PackedByteArray()
	if FileAccess.file_exists(path):
		data = FileAccess.get_file_as_bytes(path)
	_regions[key] = data
	return data


## Decompressed NBT of chunk (lx, lz) of a region file image (empty when the chunk is absent).
static func raw_chunk(rg: PackedByteArray, lx: int, lz: int) -> PackedByteArray:
	var raw := PackedByteArray()
	if rg.size() < 8192:
		return raw
	var idx := lx + lz * 32
	var off := ((rg[idx * 4] << 16) | (rg[idx * 4 + 1] << 8) | rg[idx * 4 + 2]) * 4096
	var sectors := rg[idx * 4 + 3]
	if off == 0 or sectors == 0 or off + 5 > rg.size():
		return raw
	var ln := (rg[off] << 24) | (rg[off + 1] << 16) | (rg[off + 2] << 8) | rg[off + 3]
	var comp := rg[off + 4] & 0x7f
	if ln < 1 or off + 4 + ln > rg.size():
		return raw
	var body := rg.slice(off + 5, off + 4 + ln)
	if comp == 2:
		raw = body.decompress_dynamic(-1, FileAccess.COMPRESSION_DEFLATE)
	elif comp == 1:
		raw = body.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP)
	elif comp == 3:
		raw = body
	else:
		push_warning("unsupported chunk compression %d at chunk %d,%d" % [comp, lx, lz])
	return raw


func clear_cache() -> void:
	_chunks.clear()
	_regions.clear()


func chunk(cx: int, cz: int) -> ChunkData:
	var key := Vector2i(cx, cz)
	if _chunks.has(key):
		return _chunks[key]
	if _chunks.size() >= chunk_cache_limit:
		_chunks.clear()
	var c: ChunkData = null
	var raw := raw_chunk(_region(cx >> 5, cz >> 5), cx & 31, cz & 31)
	if not raw.is_empty():
		var t0 := Time.get_ticks_usec()
		c = ChunkData.decode(raw, cx, cz, table, registry)
		stats["chunks"] += 1
		stats["chunk_ms"] += (Time.get_ticks_usec() - t0) / 1000.0
	_chunks[key] = c
	return c


func block_at(x: int, y: int, z: int) -> int:
	var c := chunk(x >> 4, z >> 4)
	if c == null:
		return 0
	return c.block(x & 15, y, z & 15)


## max(sky, block) light; 15 where the chunk is not loaded (like Dynmap's border handling).
func light_at(x: int, y: int, z: int) -> int:
	var c := chunk(x >> 4, z >> 4)
	if c == null:
		return 15
	return c.light(x & 15, y, z & 15)


func biome_at(x: int, y: int, z: int) -> int:
	var c := chunk(x >> 4, z >> 4)
	if c == null:
		return 0
	return c.biome(x & 15, y, z & 15)

