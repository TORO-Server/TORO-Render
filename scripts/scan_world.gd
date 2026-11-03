extends SceneTree
## World scan: (cx, cz, min_y, max_y) of non-air content for every full chunk, written as the little-endian int32 cache
## format shared with Dynmap-GPU (tools/mapplan.py reads it). Needs no GPU, run with --headless.
##   godot --headless -s scripts/scan_world.gd -- --region-dir DIR --out FILE [--hist 1]
## --hist 1 additionally prints a histogram of chunk Status / DataVersion values.

var _files: Array = []
var _region_dir := ""
var _results: Array = []
var _hist: Array = []


func _initialize() -> void:
	var args := _parse(OS.get_cmdline_user_args())
	_region_dir = args.get("region-dir", "")
	var out_path: String = args.get("out", "")
	if _region_dir == "" or out_path == "":
		push_error("--region-dir and --out required")
		quit(2)
		return
	for f in DirAccess.get_files_at(_region_dir):
		var p := f.split(".")
		if p.size() == 4 and p[0] == "r" and p[3] == "mca" and p[1].is_valid_int() and p[2].is_valid_int():
			_files.append([int(p[1]), int(p[2]), _region_dir.path_join(f)])
	_files.sort()
	_results.resize(_files.size())
	_hist.resize(_files.size())
	var t0 := Time.get_ticks_msec()
	var gid := WorkerThreadPool.add_group_task(_scan_region, _files.size(), -1, true, "scan regions")
	WorkerThreadPool.wait_for_group_task_completion(gid)
	var bytes := PackedInt32Array()
	var n := 0
	for r in _results:
		bytes.append_array(r)
		n += r.size() / 4
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		push_error("cannot write %s" % out_path)
		quit(1)
		return
	f.store_buffer(bytes.to_byte_array())
	f.close()
	print("scan: %d non-empty chunks in %d regions, %.1f s" % [n, _files.size(), (Time.get_ticks_msec() - t0) / 1000.0])
	if args.get("hist", "0") == "1":
		var total := {}
		for h in _hist:
			for k in h:
				total[k] = total.get(k, 0) + h[k]
		for k in total:
			print("  %s: %d" % [k, total[k]])
	quit(0)


func _scan_region(i: int) -> void:
	var info: Array = _files[i]
	var rg := FileAccess.get_file_as_bytes(info[2])
	var out := PackedInt32Array()
	var hist := {}
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
				hist["%s dv=%s" % [status, root.get("DataVersion", -1)]] = hist.get("%s dv=%s" % [status, root.get("DataVersion", -1)], 0) + 1
				if status is String and status != "minecraft:full" and status != "full" and status != "":
					continue
				var lo := 1 << 30
				var hi := -(1 << 30)
				for s in root.get("sections", []):
					var bs: Dictionary = s.get("block_states", {})
					var pal: Array = bs.get("palette", [])
					if pal.is_empty():
						continue
					if pal.size() == 1 and _is_air(pal[0]):
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
	_hist[i] = hist


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


func _parse(argv: PackedStringArray) -> Dictionary:
	var d := {}
	var i := 0
	while i < argv.size():
		var a := argv[i]
		if a.begins_with("--") and i + 1 < argv.size():
			d[a.substr(2)] = argv[i + 1]
			i += 2
		else:
			i += 1
	return d
