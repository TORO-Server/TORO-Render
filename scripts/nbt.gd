class_name Nbt
extends RefCounted
## Minimal big-endian NBT reader.
## Compound -> Dictionary, List -> Array, Byte/Int array -> Packed*Array,
## LongArray -> PackedByteArray (raw big-endian, decode with long_at()).

const T_END := 0
const T_BYTE := 1
const T_SHORT := 2
const T_INT := 3
const T_LONG := 4
const T_FLOAT := 5
const T_DOUBLE := 6
const T_BYTE_ARRAY := 7
const T_STRING := 8
const T_LIST := 9
const T_COMPOUND := 10
const T_INT_ARRAY := 11
const T_LONG_ARRAY := 12


static func parse(bytes: PackedByteArray) -> Dictionary:
	var sp := StreamPeerBuffer.new()
	sp.big_endian = true
	sp.data_array = bytes
	var tag := sp.get_u8()
	if tag != T_COMPOUND:
		return {}
	_read_string(sp)
	return _read_payload(sp, tag)


static func _read_string(sp: StreamPeerBuffer) -> String:
	var n := sp.get_u16()
	if n == 0:
		return ""
	return sp.get_utf8_string(n)


static func _read_payload(sp: StreamPeerBuffer, tag: int) -> Variant:
	match tag:
		T_BYTE:
			return sp.get_8()
		T_SHORT:
			return sp.get_16()
		T_INT:
			return sp.get_32()
		T_LONG:
			return sp.get_64()
		T_FLOAT:
			return sp.get_float()
		T_DOUBLE:
			return sp.get_double()
		T_BYTE_ARRAY:
			var n := sp.get_32()
			return sp.get_data(n)[1] as PackedByteArray
		T_STRING:
			return _read_string(sp)
		T_LIST:
			var et := sp.get_u8()
			var n := sp.get_32()
			var arr := []
			arr.resize(n)
			for i in n:
				arr[i] = _read_payload(sp, et)
			return arr
		T_COMPOUND:
			var d := {}
			while true:
				var t := sp.get_u8()
				if t == T_END:
					break
				var key := _read_string(sp)
				d[key] = _read_payload(sp, t)
			return d
		T_INT_ARRAY:
			var n := sp.get_32()
			var a := PackedInt32Array()
			a.resize(n)
			for i in n:
				a[i] = sp.get_32()
			return a
		T_LONG_ARRAY:
			var n := sp.get_32()
			return sp.get_data(n * 8)[1] as PackedByteArray
	return null


## Converts a raw big-endian long array into signed 64-bit ints.
static func longs(raw: PackedByteArray) -> PackedInt64Array:
	var n := raw.size() / 8
	var out := PackedInt64Array()
	out.resize(n)
	for i in n:
		var o := i * 8
		out[i] = (raw[o] << 56) | (raw[o + 1] << 48) | (raw[o + 2] << 40) | (raw[o + 3] << 32) \
			| (raw[o + 4] << 24) | (raw[o + 5] << 16) | (raw[o + 6] << 8) | raw[o + 7]
	return out


## Unpacks `count` palette indices of `bits` bits from a long array (no entry spans two longs, 1.16+ layout).
static func unpack(longs_arr: PackedInt64Array, bits: int, count: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(count)
	var per := 64 / bits
	var mask := (1 << bits) - 1
	for i in count:
		var li := i / per
		if li < longs_arr.size():
			out[i] = (longs_arr[li] >> ((i % per) * bits)) & mask
	return out
