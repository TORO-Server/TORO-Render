class_name TileStore
extends RefCounted
## Dynmap's TiDB tile table (dynmap_Tiles) for one MapID. Rules shared with Dynmap-GPU:
##  * (MapID, x, y, zoom) is the primary key and the image blobs are large: point lookups only, never scans
##    (all_hashes is the one explicit exception, used by --zoom-all).
##  * rows are Format=2 (lossless WebP in NewImage, Image NULL); a blank tile deletes its row.
##  * reads and writes share one byte budget (rate) so the link to the server is not saturated.

const T := 128

var map_id := 0
var rate := 8_000_000.0
var dry_run := false
## "" while healthy; the first failed statement leaves its text here
var error := ""

var _db := Mysql.new()
var _host := "127.0.0.1"
var _port := 4000
var _user := "root"
var _password := ""
var _schema := "dynmap"
var _sent := 0
var _t0 := 0


func configure(cfg: Dictionary) -> void:
	_host = cfg.get("host", _host)
	_port = int(cfg.get("port", _port))
	_user = cfg.get("user", _user)
	_password = cfg.get("password", _password)
	_schema = cfg.get("database", _schema)


func connect_db() -> bool:
	error = ""
	if not _db.open(_host, _port, _user, _password, _schema):
		error = _db.error
		return false
	_t0 = Time.get_ticks_msec()
	_sent = 0
	return true


## Reconnects when the connection dropped (a resident process outlives TiDB restarts).
func ensure_connected() -> bool:
	if _db.is_open():
		return true
	return connect_db()


func _run(sql: String) -> Array:
	var r := _db.query(sql)
	if not r["ok"]:
		error = _db.error
		return []
	return r["rows"]


func _throttle(nbytes: int) -> void:
	if rate <= 0.0:
		return
	_sent += nbytes
	var due_ms := int(_sent / rate * 1000.0)
	var elapsed := Time.get_ticks_msec() - _t0
	if due_ms > elapsed:
		OS.delay_msec(due_ms - elapsed)


func _in_clause(zoom: int, coords: Array, from: int, to: int) -> String:
	var parts := PackedStringArray()
	for i in range(from, to):
		var c: Vector2i = coords[i]
		parts.append("(%d,%d,%d,%d)" % [map_id, c.x, c.y, zoom])
	return ",".join(parts)


## Dynmap world a map belongs to ("main", "flat", "map"): the name the live player feed uses.
func world_name() -> String:
	var rows := _run("SELECT WorldID FROM dynmap_Maps WHERE ID=%d" % map_id)
	return Mysql.as_text(rows[0][0]) if not rows.is_empty() else ""


## HashCode of every existing tile among coords (Vector2i -> int).
func hashes(zoom: int, coords: Array) -> Dictionary:
	var out := {}
	for i in range(0, coords.size(), 400):
		var sql := "SELECT x,y,HashCode FROM dynmap_Tiles WHERE (MapID,x,y,zoom) IN (%s)" % _in_clause(zoom, coords, i, mini(i + 400, coords.size()))
		for row in _run(sql):
			out[Vector2i(Mysql.as_int(row[0]), Mysql.as_int(row[1]))] = Mysql.as_int(row[2])
	return out


## Decoded RGBA8 images of the existing tiles among coords (Vector2i -> Image).
func read_images(zoom: int, coords: Array) -> Dictionary:
	var out := {}
	for i in range(0, coords.size(), 100):
		var sql := "SELECT x,y,COALESCE(NewImage,Image) FROM dynmap_Tiles WHERE (MapID,x,y,zoom) IN (%s)" % _in_clause(zoom, coords, i, mini(i + 100, coords.size()))
		var nbytes := 0
		for row in _run(sql):
			if row[2] == null:
				continue
			var blob: PackedByteArray = row[2]
			nbytes += blob.size()
			var img := decode(blob)
			if img != null:
				out[Vector2i(Mysql.as_int(row[0]), Mysql.as_int(row[1]))] = img
		_throttle(nbytes)
	return out


## Tile blob (WebP, PNG or JPEG by magic number) -> 128x128 RGBA8 image, null when unreadable.
static func decode(blob: PackedByteArray) -> Image:
	var img := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	if blob.size() > 12 and blob[0] == 0x52 and blob[8] == 0x57:  # RIFF....WEBP
		err = img.load_webp_from_buffer(blob)
	elif blob.size() > 8 and blob[0] == 0x89:
		err = img.load_png_from_buffer(blob)
	elif blob.size() > 2 and blob[0] == 0xFF and blob[1] == 0xD8:
		err = img.load_jpg_from_buffer(blob)
	if err != OK or img.get_width() != T or img.get_height() != T:
		return null
	img.convert(Image.FORMAT_RGBA8)
	# the renderer writes (0,0,0,0) for empty pixels, but a lossless WebP round trip may hand back other colours there;
	# put the canonical value back so tiles rebuilt from stored children equal the ones built from fresh renders
	var d := img.get_data()
	var dirty := false
	for i in range(3, d.size(), 4):
		if d[i] == 0 and (d[i - 1] | d[i - 2] | d[i - 3]) != 0:
			d[i - 1] = 0
			d[i - 2] = 0
			d[i - 3] = 0
			dirty = true
	return Image.create_from_data(T, T, false, Image.FORMAT_RGBA8, d) if dirty else img


## tiles: Array of {"x", "y", "hash", "webp"}.
func write(zoom: int, tiles: Array, now_ms: int) -> void:
	if dry_run or tiles.is_empty():
		return
	for i in range(0, tiles.size(), 24):
		var vals := PackedStringArray()
		var nbytes := 0
		for j in range(i, mini(i + 24, tiles.size())):
			var t: Dictionary = tiles[j]
			var blob: PackedByteArray = t["webp"]
			vals.append("(%d,%d,%d,%d,%d,%d,2,X'%s',NULL)" % [map_id, t["x"], t["y"], zoom, t["hash"], now_ms, blob.hex_encode()])
			nbytes += blob.size()
		_run("INSERT INTO dynmap_Tiles (MapID,x,y,zoom,HashCode,LastUpdate,Format,NewImage,Image) VALUES " + ",".join(vals)
			+ " ON DUPLICATE KEY UPDATE HashCode=VALUES(HashCode), LastUpdate=VALUES(LastUpdate), Format=VALUES(Format),"
			+ " NewImage=VALUES(NewImage), Image=NULL")
		_throttle(nbytes)


func delete(zoom: int, coords: Array) -> void:
	if dry_run:
		return
	for c: Vector2i in coords:
		_run("DELETE FROM dynmap_Tiles WHERE MapID=%d AND zoom=%d AND x=%d AND y=%d" % [map_id, zoom, c.x, c.y])


## Subset of coords whose row was written at/after since_ms.
func updated_since(zoom: int, coords: Array, since_ms: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for i in range(0, coords.size(), 400):
		var sql := "SELECT x,y FROM dynmap_Tiles WHERE LastUpdate>=%d AND (MapID,x,y,zoom) IN (%s)" % [since_ms, _in_clause(zoom, coords, i, mini(i + 400, coords.size()))]
		for row in _run(sql):
			out.append(Vector2i(Mysql.as_int(row[0]), Mysql.as_int(row[1])))
	return out


## Every (x, y) -> HashCode of one zoom level, read in y bands. Scans the whole level: only on request.
func all_hashes(zoom: int) -> Dictionary:
	var out := {}
	var ext := _run("SELECT MIN(x),MAX(x),MIN(y),MAX(y) FROM dynmap_Tiles WHERE MapID=%d AND zoom=%d" % [map_id, zoom])
	if ext.is_empty() or ext[0][0] == null:
		return out
	var x0 := Mysql.as_int(ext[0][0])
	var x1 := Mysql.as_int(ext[0][1])
	var y0 := Mysql.as_int(ext[0][2])
	var y1 := Mysql.as_int(ext[0][3])
	var band := 64 << zoom
	var y := y0
	while y <= y1:
		var y_end := mini(y + band - 1, y1)
		var sql := "SELECT x,y,HashCode FROM dynmap_Tiles WHERE MapID=%d AND zoom=%d AND x>=%d AND x<=%d AND y>=%d AND y<=%d" % [map_id, zoom, x0, x1, y, y_end]
		for row in _run(sql):
			out[Vector2i(Mysql.as_int(row[0]), Mysql.as_int(row[1]))] = Mysql.as_int(row[2])
		y = y_end + 1
	return out
