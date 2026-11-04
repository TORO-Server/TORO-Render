class_name Nbt
extends RefCounted
## Minimal big-endian NBT reader.
## Compound -> Dictionary, List -> Array, Byte/Int array -> Packed*Array,
## LongArray -> PackedByteArray (raw big-endian, decode with long_at()).
##
## Region files are input from outside: every length is checked against the bytes left, and depth and value count are
## limited, so a damaged file costs little. parse() returns {} for anything that does not fit (the chunk counts as absent).

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

## smallest encoding of a value of each tag, to check a list's length against the bytes left
const MIN_BYTES := [0, 1, 2, 4, 8, 4, 8, 4, 2, 5, 1, 4, 4]
## levels of nesting: chunks use about 10 (a few dozen with containers inside containers)
const MAX_DEPTH := 128
## list elements and compound entries of one chunk: a full-height chunk with every palette full stays below this
const MAX_VALUES := 2_000_000


static func parse(bytes: PackedByteArray) -> Dictionary:
	var sp := StreamPeerBuffer.new()
	sp.big_endian = true
	sp.data_array = bytes
	var tag := sp.get_u8()
	if tag != T_COMPOUND:
		return {}
	var r := Reader.new(sp, bytes.size())
	r.read_string()
	var root = r.read_payload(tag, 0)
	if r.failed:
		push_warning("NBT rejected: a length or nesting limit was exceeded")
		return {}
	return root


class Reader:
	extends RefCounted
	var sp: StreamPeerBuffer
	var size := 0
	var values := 0
	var failed := false

	func _init(sp_: StreamPeerBuffer, size_: int) -> void:
		sp = sp_
		size = size_

	func read_string() -> String:
		var n := sp.get_u16()
		if n == 0:
			return ""
		if n > size - sp.get_position():
			failed = true
			return ""
		return sp.get_utf8_string(n)

	## Reserves `n` values taking `unit` bytes each; false (and failed) when they cannot be there.
	func reserve(n: int, unit: int) -> bool:
		values += n
		if n < 0 or n * unit > size - sp.get_position() or values > Nbt.MAX_VALUES:
			failed = true
			return false
		return true

	func read_payload(tag: int, depth: int) -> Variant:
		match tag:
			Nbt.T_BYTE:
				return sp.get_8()
			Nbt.T_SHORT:
				return sp.get_16()
			Nbt.T_INT:
				return sp.get_32()
			Nbt.T_LONG:
				return sp.get_64()
			Nbt.T_FLOAT:
				return sp.get_float()
			Nbt.T_DOUBLE:
				return sp.get_double()
			Nbt.T_BYTE_ARRAY:
				var n := sp.get_32()
				if n < 0 or n > size - sp.get_position():
					failed = true
					return null
				return sp.get_data(n)[1] as PackedByteArray
			Nbt.T_STRING:
				return read_string()
			Nbt.T_LIST:
				var et := sp.get_u8()
				var n := sp.get_32()
				if n <= 0:  # a length of 0 or less is an empty list, with any element type
					return []
				if depth >= Nbt.MAX_DEPTH or et == Nbt.T_END or et > Nbt.T_LONG_ARRAY or not reserve(n, Nbt.MIN_BYTES[et]):
					failed = true
					return null
				var arr := []
				arr.resize(n)
				for i in n:
					arr[i] = read_payload(et, depth + 1)
					if failed:
						return null
				return arr
			Nbt.T_COMPOUND:
				if depth >= Nbt.MAX_DEPTH:
					failed = true
					return null
				var d := {}
				while true:
					if sp.get_position() >= size:  # ran out before the end tag
						failed = true
						return null
					var t := sp.get_u8()
					if t == Nbt.T_END:
						break
					values += 1
					if values > Nbt.MAX_VALUES:
						failed = true
						return null
					var key := read_string()
					d[key] = read_payload(t, depth + 1)
					if failed:
						return null
				return d
			Nbt.T_INT_ARRAY:
				var n := sp.get_32()
				if not reserve(n, 4):
					return null
				var a := PackedInt32Array()
				a.resize(n)
				for i in n:
					a[i] = sp.get_32()
				return a
			Nbt.T_LONG_ARRAY:
				var n := sp.get_32()
				if n < 0 or n * 8 > size - sp.get_position():
					failed = true
					return null
				return sp.get_data(n * 8)[1] as PackedByteArray
		failed = true  # not a tag
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
