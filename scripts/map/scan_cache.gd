class_name ScanCache
extends RefCounted
## World scan: (cx, cz, min_y, max_y) of the non-air content of every full chunk. The file is the little-endian int32
## cache format: four int32 per chunk.

var quads := PackedInt32Array()

var _files: Array = []
var _results: Array = []


static func load_file(path: String) -> ScanCache:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty() or bytes.size() % 16 != 0:
		return null
	var c := ScanCache.new()
	c.quads = bytes.to_int32_array()
	return c


func save(path: String) -> bool:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(quads.to_byte_array())
	return true


func count() -> int:
	return quads.size() / 4


func min_y() -> int:
	var v := 1 << 30
	for i in range(2, quads.size(), 4):
		v = mini(v, quads[i])
	return v


func max_y() -> int:
	var v := -(1 << 30)
	for i in range(3, quads.size(), 4):
		v = maxi(v, quads[i])
	return v


## Scans every region file of a directory on all cores (NBT parse of each chunk header).
static func build(region_dir: String) -> ScanCache:
	var c := ScanCache.new()
	for f in DirAccess.get_files_at(region_dir):
		var rc := WorldReader.region_coords(f)
		if not rc.is_empty():
			c._files.append([rc[0], rc[1], region_dir.path_join(f)])
	c._files.sort()
	c._results.resize(c._files.size())
	var gid := WorkerThreadPool.add_group_task(c._scan_region, c._files.size(), -1, true, "scan regions")
	WorkerThreadPool.wait_for_group_task_completion(gid)
	for r in c._results:
		c.quads.append_array(r)
	return c


func _scan_region(i: int) -> void:
	var info: Array = _files[i]
	var rg := WorldReader.read_region(info[2])
	var out := PackedInt32Array()
	if rg.size() >= 8192:
		for lz in 32:
			for lx in 32:
				var raw := WorldReader.raw_chunk(rg, lx, lz)
				if raw.is_empty():
					continue
				var root := Nbt.parse(raw)
				if root.is_empty():
					continue
				var status = root.get("Status", "")
				if status is String and status != "minecraft:full" and status != "full" and status != "":
					continue
				var lo := 1 << 30
				var hi := -(1 << 30)
				var secs = root.get("sections", [])
				if not secs is Array:
					continue
				for s in secs:
					# these values size the tile ranges of the plan: anything ChunkData.decode would refuse does not count
					if not s is Dictionary or not ChunkData.valid_section_y(s.get("Y")):
						continue
					var bs = s.get("block_states", {})
					var pal = bs.get("palette", []) if bs is Dictionary else []
					if not pal is Array or pal.is_empty() or (pal.size() == 1 and _is_air(pal[0])):
						continue
					var y: int = s["Y"]
					lo = mini(lo, y * 16)
					hi = maxi(hi, y * 16 + 16)
				if lo <= hi:
					out.append(info[0] * 32 + lx)
					out.append(info[1] * 32 + lz)
					out.append(lo)
					out.append(hi)
	_results[i] = out


static func _is_air(v: Variant) -> bool:
	var n := "minecraft:air"
	if v is String:
		n = v
	elif v is Dictionary:
		for k in ["Name", "name", "id", ""]:
			if v.has(k) and v[k] is String:
				n = v[k]
				break
	return n == "minecraft:air" or n == "minecraft:cave_air" or n == "minecraft:void_air"
