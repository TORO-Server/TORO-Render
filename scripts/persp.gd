class_name Persp
extends RefCounted
## Port of Dynmap's IsoHDPerspective world<->map transform (Dynmap-GPU persp.rs). 3x3 matrices are row-major
## PackedFloat64Array(9); all maths in double precision like the Rust version.

var name := ""
var scale := 4
var inclination := 90.0
var w2m := PackedFloat64Array()
var m2w := PackedFloat64Array()


static func _ident() -> PackedFloat64Array:
	return PackedFloat64Array([1, 0, 0, 0, 1, 0, 0, 0, 1])


## this = m * this
static func _mul(a: PackedFloat64Array, m: PackedFloat64Array) -> PackedFloat64Array:
	var r := PackedFloat64Array()
	r.resize(9)
	for i in 3:
		for j in 3:
			r[i * 3 + j] = m[i * 3] * a[j] + m[i * 3 + 1] * a[3 + j] + m[i * 3 + 2] * a[6 + j]
	return r


static func _scale(a: PackedFloat64Array, s1: float, s2: float, s3: float) -> PackedFloat64Array:
	return _mul(a, PackedFloat64Array([s1, 0, 0, 0, s2, 0, 0, 0, s3]))


static func _rot_xy(a: PackedFloat64Array, deg: float) -> PackedFloat64Array:
	var r := deg_to_rad(deg)
	var s := sin(r)
	var c := cos(r)
	return _mul(a, PackedFloat64Array([c, s, 0, -s, c, 0, 0, 0, 1]))


static func _rot_yz(a: PackedFloat64Array, deg: float) -> PackedFloat64Array:
	var r := deg_to_rad(deg)
	var s := sin(r)
	var c := cos(r)
	return _mul(a, PackedFloat64Array([1, 0, 0, 0, c, s, 0, -s, c]))


static func _shear_z(a: PackedFloat64Array, xf: float, yf: float) -> PackedFloat64Array:
	return _mul(a, PackedFloat64Array([1, 0, 0, 0, 1, 0, xf, yf, 1]))


static func make(name_: String, azimuth_cfg: float, incl: float, scale_: int) -> Persp:
	var p := Persp.new()
	p.name = name_
	p.scale = scale_
	p.inclination = incl
	var az := 90.0 + azimuth_cfg
	if az >= 360.0:
		az -= 360.0
	var s := float(scale_)
	var t := PackedFloat64Array([0, 0, -1, -1, 0, 0, 0, 1, 0])
	t = _rot_xy(t, 180.0 - az)
	t = _rot_yz(t, 90.0 - incl)
	t = _shear_z(t, 0.0, tan(deg_to_rad(90.0 - incl)))
	t = _scale(t, s, s, sin(deg_to_rad(incl)))
	p.w2m = t
	var u := _ident()
	u = _scale(u, 1.0 / s, 1.0 / s, 1.0 / sin(deg_to_rad(incl)))
	u = _shear_z(u, 0.0, -tan(deg_to_rad(90.0 - incl)))
	u = _rot_yz(u, -(90.0 - incl))
	u = _rot_xy(u, -180.0 + az)
	u = _mul(u, PackedFloat64Array([0, -1, 0, 0, 0, 1, -1, 0, 0]))
	p.m2w = u
	return p


static func by_name(n: String) -> Persp:
	match n:
		"iso_S_90_lowres":
			return make(n, 180.0, 90.0, 4)
		"iso_S_90_hires":
			return make(n, 180.0, 90.0, 16)
		"iso_SE_30_hires":
			return make(n, 135.0, 30.0, 16)
		"iso_SE_30_lowres":
			return make(n, 135.0, 30.0, 4)
	return null


## Results are PackedFloat64Array(3): Vector3 would drop to single precision.
func world_to_map(wx: float, wy: float, wz: float) -> PackedFloat64Array:
	var m := w2m
	return PackedFloat64Array([m[0] * wx + m[1] * wy + m[2] * wz, m[3] * wx + m[4] * wy + m[5] * wz, m[6] * wx + m[7] * wy + m[8] * wz])


func map_to_world(mx: float, my: float, mz: float) -> PackedFloat64Array:
	var m := m2w
	return PackedFloat64Array([m[0] * mx + m[1] * my + m[2] * mz, m[3] * mx + m[4] * my + m[5] * mz, m[6] * mx + m[7] * my + m[8] * mz])


## True when an upward-facing quad winds counter-clockwise in map space (selects the front-face sense).
func front_ccw() -> bool:
	var a := world_to_map(0, 1, 0)
	var b := world_to_map(0, 1, 1)
	var c := world_to_map(1, 1, 1)
	return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]) > 0.0
