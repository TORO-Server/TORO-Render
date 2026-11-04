class_name TileCodec
extends RefCounted
## Dynmap tile image helpers: CRC32 HashCode (ARGB ints little-endian = B,G,R,A bytes), blank test, lossless WebP.

static var _crc_table := PackedInt64Array()  # 64-bit: entries above 2^31 must stay positive


static func _init_table() -> void:
	if not _crc_table.is_empty():
		return
	_crc_table.resize(256)
	for n in 256:
		var c := n
		for _k in 8:
			c = (0xEDB88320 ^ (c >> 1)) if (c & 1) == 1 else (c >> 1)
		_crc_table[n] = c


## Dynmap MapStorage.calculateImageHashCode over the ARGB ints of an RGBA8 buffer.
static func crc_hash(rgba: PackedByteArray) -> int:
	_init_table()
	var c := 0xFFFFFFFF
	var tbl := _crc_table
	for i in range(0, rgba.size(), 4):
		c = tbl[(c ^ rgba[i + 2]) & 255] ^ (c >> 8)
		c = tbl[(c ^ rgba[i + 1]) & 255] ^ (c >> 8)
		c = tbl[(c ^ rgba[i]) & 255] ^ (c >> 8)
		c = tbl[(c ^ rgba[i + 3]) & 255] ^ (c >> 8)
	return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF


static func is_blank(rgba: PackedByteArray) -> bool:
	for i in range(3, rgba.size(), 4):
		if rgba[i] != 0:
			return false
	return true


## Lossless WebP as stored in dynmap_Tiles.NewImage with Format=2.
static func encode_webp(img: Image) -> PackedByteArray:
	return img.save_webp_to_buffer(false, 1.0)
