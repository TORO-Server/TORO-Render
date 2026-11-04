class_name AnvilChanges
extends RefCounted
## Finds chunks the game server saved since a point in time. Every Anvil region file keeps a "last saved" timestamp per
## chunk in its header, so terrain generated while players explore and blocks placed or broken show up without any
## hook into the server. Region files whose mtime did not move are not opened.

## second resolution: a file modified in the last couple of seconds is looked at again next time
const SETTLE_SECONDS := 2

## region file name -> mtime already examined
var mtimes := {}


## Chunks (Vector2i) saved after `since` (epoch seconds).
func changed_since(region_dir: String, since: float) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var now := Time.get_unix_time_from_system()
	for f in DirAccess.get_files_at(region_dir):
		var rc := WorldReader.region_coords(f)
		if rc.is_empty():
			continue
		var path := region_dir.path_join(f)
		var mt := FileAccess.get_modified_time(path)
		if mtimes.get(f, -1) == mt:
			continue
		if now - mt > SETTLE_SECONDS:
			mtimes[f] = mt
		if mt < since:
			continue
		var fh := FileAccess.open(path, FileAccess.READ)
		if fh == null:
			continue
		var head := fh.get_buffer(8192)
		fh.close()
		if head.size() < 8192:
			continue
		var rx: int = rc[0]
		var rz: int = rc[1]
		for i in 1024:
			var o := 4096 + i * 4
			var ts := (head[o] << 24) | (head[o + 1] << 16) | (head[o + 2] << 8) | head[o + 3]
			if ts > since and head[i * 4 + 3] != 0:
				out.append(Vector2i(rx * 32 + i % 32, rz * 32 + i / 32))
	return out


## Mega tiles (Vector2i) any of the chunks - and their 8 neighbours, whose light and face culling look one chunk over -
## can project into.
static func megas_of(chunks: Array[Vector2i], persp: Persp, y0: float, y1: float, mega: int) -> Array[Vector2i]:
	var ring := {}
	for c in chunks:
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				ring[Vector2i(c.x + dx, c.y + dz)] = true
	var keys := PackedInt64Array()
	for c: Vector2i in ring:
		Planner.chunk_tiles(persp, c.x, c.y, y0, y1, keys)
	var seen := {}
	for k in keys:
		seen[Vector2i(ZoomBuilder.floor_div(Planner.key_a(k), mega), ZoomBuilder.floor_div(Planner.key_b(k), mega))] = true
	var out: Array[Vector2i] = []
	out.assign(seen.keys())
	return out
