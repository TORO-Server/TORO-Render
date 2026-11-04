class_name Publisher
extends RefCounted
## Writes rendered zoom-0 tiles to the tile table with Dynmap-GPU's rules (driver.rs):
##  * a tile is wanted when it is a candidate (inside the planned set) or already has a row; with only_missing, when it is
##    a candidate without a row;
##  * an unchanged HashCode is skipped, a blank tile deletes an existing row.

var store: TileStore
## sorted tile keys of the plan; empty = every rendered tile is a candidate
var candidates := PackedInt64Array()
var only_missing := false


func _init(store_: TileStore) -> void:
	store = store_


## tiles: Vector2i -> null | {"img", "hash"}. Returns {"changed": Vector2i -> Image|null, "text": summary}.
func upload(tiles: Dictionary, now_ms: int) -> Dictionary:
	var existing := store.hashes(0, tiles.keys())
	var changed := {}
	var writes := []
	var drops: Array[Vector2i] = []
	var same := 0
	var blank := 0
	for xy: Vector2i in tiles:
		var is_cand := candidates.is_empty() or Planner.has(candidates, xy.x, xy.y)
		var wanted := (is_cand and not existing.has(xy)) if only_missing else (is_cand or existing.has(xy))
		if not wanted:
			continue
		var t = tiles[xy]
		if t == null:
			blank += 1
			if existing.has(xy):
				drops.append(xy)
				changed[xy] = null
			continue
		if existing.get(xy, -1) == t["hash"]:
			same += 1
			continue
		writes.append({"x": xy.x, "y": xy.y, "hash": t["hash"], "webp": TileCodec.encode_webp(t["img"])})
		changed[xy] = t["img"]
	store.write(0, writes, now_ms)
	store.delete(0, drops)
	return {"changed": changed, "text": "zoom 0: wrote %d, deleted %d, unchanged %d, blank %d" % [writes.size(), drops.size(), same, blank]}
