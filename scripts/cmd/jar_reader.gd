class_name JarReader
extends RefCounted
## Reads a .jar/.zip from memory with a name index built once. (ZIPReader.read_file walks the central directory for every
## call, ~0.2 s each on a jar with 40k entries.) Deflated entries are inflated by wrapping the raw stream into a gzip
## container - the zip directory already holds the CRC32 and the size gzip wants in its trailer.

var _data := PackedByteArray()
var _index := {}  # name -> [header offset, compressed size, size, crc32, method]


func open(path: String) -> bool:
	_data = FileAccess.get_file_as_bytes(path)
	if _data.size() < 22:
		return false
	var eocd := -1
	for i in range(_data.size() - 22, maxi(_data.size() - 65558, -1), -1):
		if _data.decode_u32(i) == 0x06054B50:
			eocd = i
			break
	if eocd < 0:
		return false
	var entries := _data.decode_u16(eocd + 10)
	var pos := _data.decode_u32(eocd + 16)
	for _i in entries:
		if _data.decode_u32(pos) != 0x02014B50:
			return false
		var name_len := _data.decode_u16(pos + 28)
		var extra_len := _data.decode_u16(pos + 30)
		var comment_len := _data.decode_u16(pos + 32)
		var name := _data.slice(pos + 46, pos + 46 + name_len).get_string_from_utf8()
		_index[name] = [_data.decode_u32(pos + 42), _data.decode_u32(pos + 20), _data.decode_u32(pos + 24), _data.decode_u32(pos + 16), _data.decode_u16(pos + 10)]
		pos += 46 + name_len + extra_len + comment_len
	return true


func names() -> PackedStringArray:
	return PackedStringArray(_index.keys())


func has(name: String) -> bool:
	return _index.has(name)


func read(name: String) -> PackedByteArray:
	if not _index.has(name):
		return PackedByteArray()
	var e: Array = _index[name]
	var header: int = e[0]
	var start := header + 30 + _data.decode_u16(header + 26) + _data.decode_u16(header + 28)
	var body := _data.slice(start, start + e[1])
	if e[4] == 0:
		return body
	if e[4] != 8:
		return PackedByteArray()
	var gz := PackedByteArray([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF])
	gz.append_array(body)
	for v: int in [e[3], e[2]]:  # CRC32, ISIZE (little endian)
		for k in 4:
			gz.append((v >> (8 * k)) & 0xFF)
	return gz.decompress(e[2], FileAccess.COMPRESSION_GZIP) if e[2] > 0 else PackedByteArray()
