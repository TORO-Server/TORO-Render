class_name Planner
extends RefCounted
## Which tiles and mega tiles a set of chunks touches.
## Tile and mega coordinates are packed into sortable int64 keys: first coordinate in the high 32 bits, second biased by
## 2^31, so a sorted PackedInt64Array is ordered by (first, second).

const TILE := 128


static func key(a: int, b: int) -> int:
	return (a << 32) | ((b + 0x80000000) & 0xFFFFFFFF)


static func key_a(k: int) -> int:
	return k >> 32


static func key_b(k: int) -> int:
	return (k & 0xFFFFFFFF) - 0x80000000


static func unique_sorted(a: PackedInt64Array) -> PackedInt64Array:
	a.sort()
	var out := PackedInt64Array()
	var last := 0
	for i in a.size():
		if i == 0 or a[i] != last:
			out.append(a[i])
			last = a[i]
	return out


static func has(keys: PackedInt64Array, x: int, y: int) -> bool:
	var k := key(x, y)
	var i := keys.bsearch(k)
	return i < keys.size() and keys[i] == k


## Appends the keys of every zoom-0 tile the chunk (cx, cz) can project into when its blocks span y in [lo, hi].
static func chunk_tiles(persp: Persp, cx: int, cz: int, lo: float, hi: float, out: PackedInt64Array) -> void:
	var m := persp.w2m
	var s := float(persp.scale)
	var x0 := INF
	var x1 := -INF
	var y0 := INF
	var y1 := -INF
	for wx in [cx * 16.0, cx * 16.0 + 16.0]:
		for wz in [cz * 16.0, cz * 16.0 + 16.0]:
			for wy in [lo, hi]:
				var mx: float = m[0] * wx + m[1] * wy + m[2] * wz
				var my: float = m[3] * wx + m[4] * wy + m[5] * wz
				x0 = minf(x0, mx)
				x1 = maxf(x1, mx)
				y0 = minf(y0, my)
				y1 = maxf(y1, my)
	for ty in range(floori((y0 - s) / TILE), floori((y1 + s) / TILE) + 1):
		for tx in range(floori((x0 - s) / TILE), floori((x1 + s) / TILE) + 1):
			out.append(key(tx, ty))


## Sorted unique keys of every tile any scanned chunk can project into.
static func tile_keys(scan: ScanCache, persp: Persp) -> PackedInt64Array:
	var acc := PackedInt64Array()
	var fresh := PackedInt64Array()
	var q := scan.quads
	for i in range(0, q.size(), 4):
		chunk_tiles(persp, q[i], q[i + 1], q[i + 2], q[i + 3], fresh)
		if fresh.size() > 4_000_000:
			acc.append_array(fresh)
			fresh.clear()
			acc = unique_sorted(acc)
	acc.append_array(fresh)
	return unique_sorted(acc)


## Floor division by `mega` of the tile keys (optionally limited to bbox tx0,ty0,tx1,ty1) -> {"keys": kept tile keys,
## "megas": Array[Vector2i] in row order (my, then mx)}.
static func megas_of(keys: PackedInt64Array, mega: int, bbox := PackedInt32Array()) -> Dictionary:
	var kept := PackedInt64Array()
	var mk := PackedInt64Array()
	for k in keys:
		var tx := key_a(k)
		var ty := key_b(k)
		if bbox.size() == 4 and (tx < bbox[0] or tx > bbox[2] or ty < bbox[1] or ty > bbox[3]):
			continue
		kept.append(k)
		mk.append(key(ZoomBuilder.floor_div(ty, mega), ZoomBuilder.floor_div(tx, mega)))
	var megas: Array[Vector2i] = []
	for k in unique_sorted(mk):
		megas.append(Vector2i(key_b(k), key_a(k)))
	return {"keys": kept, "megas": megas}


## Mega tiles with at least one candidate tile that has no row yet -> {"megas", "missing" (tiles)}.
static func missing_megas(store: TileStore, keys: PackedInt64Array, megas: Array[Vector2i], mega: int, log_fn: Callable) -> Dictionary:
	var per_mega := {}
	for k in keys:
		var mk := Vector2i(ZoomBuilder.floor_div(key_a(k), mega), ZoomBuilder.floor_div(key_b(k), mega))
		if not per_mega.has(mk):
			per_mega[mk] = []
		per_mega[mk].append(Vector2i(key_a(k), key_b(k)))
	var keep: Array[Vector2i] = []
	var tally := {"missing": 0}  # a lambda copies plain ints, so the count lives in a dictionary
	var batch_m := []
	var batch_c := []
	var flush := func() -> void:
		var have := store.hashes(0, batch_c) if not batch_c.is_empty() else {}
		for e in batch_m:
			var n := 0
			for c in e[1]:
				if not have.has(c):
					n += 1
			if n > 0:
				keep.append(e[0])
				tally["missing"] += n
		batch_m.clear()
		batch_c.clear()
	var done := 0
	for m in megas:
		var cs: Array = per_mega.get(m, [])
		batch_m.append([m, cs])
		batch_c.append_array(cs)
		done += 1
		if batch_c.size() >= 400:
			flush.call()
		if done % 2000 == 0:
			log_fn.call("checked %d/%d" % [done, megas.size()])
		if store.error != "":
			break
	flush.call()
	return {"megas": keep, "missing": tally["missing"]}
