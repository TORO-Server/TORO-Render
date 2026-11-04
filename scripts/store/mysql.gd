class_name Mysql
extends RefCounted
## Minimal MySQL client (text protocol, mysql_native_password) over StreamPeerTCP: enough for TiDB's dynmap_Tiles table.
## No TLS, no prepared statements: blobs go into the SQL as X'hex' literals. Calls block; nothing here yields.

const CLIENT_LONG_PASSWORD := 0x1
const CLIENT_CONNECT_WITH_DB := 0x8
const CLIENT_PROTOCOL_41 := 0x200
const CLIENT_TRANSACTIONS := 0x2000
const CLIENT_SECURE_CONNECTION := 0x8000
const CLIENT_PLUGIN_AUTH := 0x80000
const MAX_PACKET := 0xFFFFFF

var timeout_ms := 60000
## text of the last failure, "" while healthy
var error := ""

var _tcp := StreamPeerTCP.new()
var _seq := 0


func is_open() -> bool:
	_tcp.poll()
	return error == "" and _tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED


func open(host: String, port: int, user: String, password: String, database: String) -> bool:
	close()
	error = ""
	if _tcp.connect_to_host(host, port) != OK:
		return _fail("cannot connect to %s:%d" % [host, port])
	var deadline := Time.get_ticks_msec() + timeout_ms
	while true:
		_tcp.poll()
		var st := _tcp.get_status()
		if st == StreamPeerTCP.STATUS_CONNECTED:
			break
		if st == StreamPeerTCP.STATUS_ERROR or Time.get_ticks_msec() > deadline:
			return _fail("cannot connect to %s:%d" % [host, port])
		OS.delay_msec(2)
	_tcp.set_no_delay(true)
	var hello := _read_packet()
	if hello.is_empty():
		return false
	if hello[0] == 0xFF:
		return _fail("server refused: " + _err_text(hello))
	var salt := _parse_salt(hello)
	var caps := CLIENT_LONG_PASSWORD | CLIENT_CONNECT_WITH_DB | CLIENT_PROTOCOL_41 | CLIENT_TRANSACTIONS \
		| CLIENT_SECURE_CONNECTION | CLIENT_PLUGIN_AUTH
	var r := PackedByteArray()
	_put_u32(r, caps)
	_put_u32(r, 0x01000000)
	r.append(45)  # utf8mb4_general_ci
	r.resize(r.size() + 23)
	r.append_array(user.to_utf8_buffer())
	r.append(0)
	var auth := _scramble(password, salt)
	r.append(auth.size())
	r.append_array(auth)
	r.append_array(database.to_utf8_buffer())
	r.append(0)
	r.append_array("mysql_native_password".to_utf8_buffer())
	r.append(0)
	if not _write_packet(r):
		return false
	var resp := _read_packet()
	if resp.is_empty():
		return false
	if resp[0] == 0xFE:  # auth switch: plugin\0 salt\0
		var nul := resp.find(0, 1)
		var plugin := resp.slice(1, nul).get_string_from_ascii()
		if plugin != "mysql_native_password":
			return _fail("unsupported auth plugin " + plugin)
		if not _write_packet(_scramble(password, resp.slice(nul + 1, resp.size() - 1))):
			return false
		resp = _read_packet()
		if resp.is_empty():
			return false
	if resp[0] == 0xFF:
		return _fail("login failed: " + _err_text(resp))
	return true


func close() -> void:
	if _tcp.get_status() != StreamPeerTCP.STATUS_NONE:
		_tcp.disconnect_from_host()


## Runs one statement. SELECT -> rows as Array of Array (cells are PackedByteArray, null for SQL NULL);
## anything else -> empty rows. Returns {"ok", "rows", "affected"}; on failure `error` is set and ok is false.
func query(sql: String) -> Dictionary:
	var res := {"ok": false, "rows": [], "affected": 0}
	_seq = 0
	var payload := PackedByteArray([0x03])
	payload.append_array(sql.to_utf8_buffer())
	if not _write_packet(payload):
		return res
	var p := _read_packet()
	if p.is_empty():
		return res
	if p[0] == 0xFF:
		_fail(_err_text(p))
		return res
	if p[0] == 0x00:
		res["affected"] = _lenenc(p, 1)[0]
		res["ok"] = true
		return res
	var ncols: int = _lenenc(p, 0)[0]
	for _i in ncols:  # column definitions, ignored
		if _read_packet().is_empty():
			return res
	if _read_packet().is_empty():  # EOF after the definitions
		return res
	var rows := []
	while true:
		p = _read_packet()
		if p.is_empty():
			return res
		if p[0] == 0xFF:
			_fail(_err_text(p))
			return res
		if p[0] == 0xFE and p.size() < 9:
			break
		var row := []
		var pos := 0
		for _c in ncols:
			if p[pos] == 0xFB:
				row.append(null)
				pos += 1
				continue
			var l := _lenenc(p, pos)
			row.append(p.slice(l[1], l[1] + l[0]))
			pos = l[1] + l[0]
		rows.append(row)
	res["rows"] = rows
	res["ok"] = true
	return res


static func as_int(cell: Variant) -> int:
	return (cell as PackedByteArray).get_string_from_ascii().to_int()


static func as_text(cell: Variant) -> String:
	return (cell as PackedByteArray).get_string_from_utf8()


# --- wire format ------------------------------------------------------------------------------------------------


func _fail(msg: String) -> bool:
	error = msg
	push_warning("mysql: " + msg)
	return false


static func _put_u32(b: PackedByteArray, v: int) -> void:
	for i in 4:
		b.append((v >> (8 * i)) & 0xFF)


static func _err_text(p: PackedByteArray) -> String:
	var errno := p[1] | (p[2] << 8)
	var from := 9 if p.size() > 9 and p[3] == 0x23 else 3  # '#' + 5 byte SQL state
	return "%d %s" % [errno, p.slice(from).get_string_from_utf8()]


static func _parse_salt(hello: PackedByteArray) -> PackedByteArray:
	var i := hello.find(0, 1) + 1  # after the server version
	i += 4  # connection id
	var salt := hello.slice(i, i + 8)
	i += 8 + 1 + 2 + 1 + 2 + 2  # filler, caps low, charset, status, caps high
	var auth_len := hello[i]
	i += 1 + 10
	salt.append_array(hello.slice(i, i + maxi(13, auth_len - 8) - 1))  # without the trailing NUL
	return salt


static func _sha1(b: PackedByteArray) -> PackedByteArray:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA1)
	h.update(b)
	return h.finish()


## SHA1(password) XOR SHA1(salt + SHA1(SHA1(password))); empty password -> empty response
static func _scramble(password: String, salt: PackedByteArray) -> PackedByteArray:
	if password == "":
		return PackedByteArray()
	var s1 := _sha1(password.to_utf8_buffer())
	var s2 := _sha1(s1)
	var mix := salt.duplicate()
	mix.append_array(s2)
	var s3 := _sha1(mix)
	var out := PackedByteArray()
	for i in 20:
		out.append(s1[i] ^ s3[i])
	return out


## [value, next position]
static func _lenenc(p: PackedByteArray, pos: int) -> Array:
	var b := p[pos]
	if b < 0xFB:
		return [b, pos + 1]
	if b == 0xFC:
		return [p[pos + 1] | (p[pos + 2] << 8), pos + 3]
	if b == 0xFD:
		return [p[pos + 1] | (p[pos + 2] << 8) | (p[pos + 3] << 16), pos + 4]
	return [p.decode_u64(pos + 1), pos + 9]


func _read_exact(n: int) -> PackedByteArray:
	var out := PackedByteArray()
	var deadline := Time.get_ticks_msec() + timeout_ms
	while out.size() < n:
		_tcp.poll()
		if _tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_fail("connection lost")
			return PackedByteArray()
		var avail := _tcp.get_available_bytes()
		if avail <= 0:
			if Time.get_ticks_msec() > deadline:
				_fail("timeout")
				return PackedByteArray()
			OS.delay_msec(1)
			continue
		var part := _tcp.get_partial_data(mini(avail, n - out.size()))
		if part[0] != OK:
			_fail("read error")
			return PackedByteArray()
		out.append_array(part[1])
	return out


## One logical packet (continuation packets of 16 MB payloads are joined); empty on failure.
func _read_packet() -> PackedByteArray:
	var payload := PackedByteArray()
	while true:
		var head := _read_exact(4)
		if head.is_empty():
			return PackedByteArray()
		var n := head[0] | (head[1] << 8) | (head[2] << 16)
		_seq = (head[3] + 1) & 0xFF
		if n > 0:
			var body := _read_exact(n)
			if body.is_empty():
				return PackedByteArray()
			payload.append_array(body)
		if n < MAX_PACKET:
			break
	if payload.is_empty():
		_fail("empty packet")
	return payload


func _write_packet(payload: PackedByteArray) -> bool:
	var pos := 0
	while true:
		var n := mini(payload.size() - pos, MAX_PACKET)
		var frame := PackedByteArray([n & 0xFF, (n >> 8) & 0xFF, (n >> 16) & 0xFF, _seq])
		_seq = (_seq + 1) & 0xFF
		frame.append_array(payload.slice(pos, pos + n))
		if _tcp.put_data(frame) != OK:
			return _fail("write error")
		pos += n
		if n < MAX_PACKET:
			break
	return true
