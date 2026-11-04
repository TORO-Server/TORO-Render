class_name BuildData
extends RefCounted
## `build-data --jar client.jar [--reports blocks.json] [--out data]`: everything the renderer reads from a Minecraft
## client jar (and, for block default properties, the data generator's blocks report).
##
## For BlockTable (the column-level lookup):
##   blocks.json   block name -> [tex index, kind, tint]; kind 0 = not drawn from above, 1 = solid top face, 2 = fluid;
##                 tint 0 none, 1 grass, 2 foliage, 3 water, 0x1000000|rgb fixed colour
##   atlas.bin     tex count * 16 texels * RGBA8: every texture box-resampled to 4x4 (alpha weighted, like Dynmap's lowres)
##   atlas.json    tex index -> texture name (debugging)
##   biomes.json   biome name -> [grass, foliage, water] RGB ints
## For StateRegistry (real block models):
##   assets/blockstates/*.json, assets/models/block/**.json   raw definitions (parents are resolved at run time)
##   textures.bin  count * 16*16*4 RGBA8, first animation frame, box-resampled to 16x16 like Dynmap-GPU; index 0 = checker
##   textures.json texture index -> name ("block/stone")
##   block_defaults.json  block name -> default property values (needs --reports)

const TEX := 16
const S := 4
const FIXED_FOLIAGE := {"spruce_leaves": 0x619961, "birch_leaves": 0x80A755, "lily_pad": 0x208030}
const WATER_BLOCKS := ["water", "bubble_column", "kelp", "kelp_plant", "seagrass", "tall_seagrass"]
const NEVER_DRAWN := ["air", "cave_air", "void_air", "barrier", "light", "structure_void", "moving_piston", "piston_head"]

var _jar := JarReader.new()
var _names := PackedStringArray()
var _atlas_index := {}
var _atlas_names: Array[String] = []
var _atlas := PackedByteArray()
var _model_cache := {}


static func run(args: Args) -> int:
	var jar := args.text("jar")
	if jar == "":
		push_error("build-data needs --jar <client jar>")
		return 2
	var b := BuildData.new()
	return b._build(jar, args.text("out", ProjectSettings.globalize_path("res://data")), args.text("reports"))


func _json(name: String) -> Variant:
	if not _jar.has(name):
		return null
	return JSON.parse_string(_jar.read(name).get_string_from_utf8())


static func _strip_ns(s: String) -> String:
	return s.split(":", true, 1)[1] if ":" in s else s


static var _made_dirs := {}


static func _write(path: String, bytes: PackedByteArray) -> void:
	var dir := path.get_base_dir()
	if not _made_dirs.has(dir):
		DirAccess.make_dir_recursive_absolute(dir)
		_made_dirs[dir] = true
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(bytes)


static func _write_json(path: String, v: Variant) -> void:
	_write(path, JSON.stringify(v, "", false).to_utf8_buffer())


func _build(jar: String, out: String, reports: String) -> int:
	if not _jar.open(jar):
		push_error("cannot open %s" % jar)
		return 1
	_names = _jar.names()
	_names.sort()

	var blocks := {}
	var prefix := "assets/minecraft/blockstates/"
	for n in _names:
		if not (n.begins_with(prefix) and n.ends_with(".json")):
			continue
		var short := n.substr(prefix.length(), n.length() - prefix.length() - 5)
		blocks["minecraft:" + short] = _classify(short, n)
	_write_json(out.path_join("blocks.json"), blocks)
	_write(out.path_join("atlas.bin"), _atlas)
	_write_json(out.path_join("atlas.json"), _atlas_names)
	_write_json(out.path_join("biomes.json"), _biomes())
	var solid := 0
	for v in blocks.values():
		if v[1] == 1:
			solid += 1
	print("blocks %d (solid %d), textures %d, biomes written" % [blocks.size(), solid, _atlas_names.size()])

	var counts := {"blockstates": 0, "models": 0}
	for n in _names:
		for pair in [["assets/minecraft/blockstates/", "blockstates"], ["assets/minecraft/models/block/", "models"]]:
			if n.begins_with(pair[0]) and n.ends_with(".json"):
				_write(out.path_join("assets").path_join(n.substr("assets/minecraft/".length())), _jar.read(n))
				counts[pair[1]] += 1
	var tex_names: Array[String] = ["missingno"]
	var data := PackedByteArray()
	for y in TEX:
		for x in TEX:
			data.append_array([248, 0, 248, 255] if (x / 8 + y / 8) % 2 == 0 else [0, 0, 0, 255])
	var skipped := 0
	var tex_prefix := "assets/minecraft/textures/block/"
	for n in _names:
		if n.begins_with(tex_prefix) and n.ends_with(".png"):
			var t := _decode16(_jar.read(n))
			if t.is_empty():
				skipped += 1
				continue
			tex_names.append(n.substr("assets/minecraft/textures/".length(), n.length() - "assets/minecraft/textures/".length() - 4))
			data.append_array(t)
	_write(out.path_join("textures.bin"), data)
	_write_json(out.path_join("textures.json"), tex_names)
	var defaults := {}
	if reports != "" and FileAccess.file_exists(reports):
		var rep: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(reports))
		for bname in rep:
			for st in rep[bname].get("states", []):
				if st.get("default", false):
					var props := {}
					for k in st.get("properties", {}):
						props[k] = str(st["properties"][k])
					defaults[bname] = props
	else:
		print("warning: no --reports blocks.json, default block properties unavailable")
	_write_json(out.path_join("block_defaults.json"), defaults)
	print("blockstates %d, models %d, textures %d (skipped %d), defaults %d" % [counts["blockstates"], counts["models"], tex_names.size(), skipped, defaults.size()])
	return 0


# --- BlockTable data --------------------------------------------------------------------------------------------


func _classify(short: String, state_path: String) -> Array:
	if NEVER_DRAWN.has(short):
		return [0, 0, 0]
	if WATER_BLOCKS.has(short):
		return [_atlas_add("block/water_still"), 2, 3]
	if short == "lava":
		return [_atlas_add("block/lava_still"), 2, 0]
	var state = _json(state_path)
	var mref := _first_model(state) if state is Dictionary else ""
	var model = _load_model(mref) if mref != "" else null
	if model == null or model["builtin"]:
		return [0, 0, 0]
	var tf := _top_face(model)
	if tf.is_empty() or tf[0] == "":
		return [0, 0, 0]
	var tex := _atlas_add(tf[0])
	if tex < 0:
		return [0, 0, 0]
	var tint := 0
	if tf[1] != null:
		if FIXED_FOLIAGE.has(short):
			tint = 0x1000000 | FIXED_FOLIAGE[short]
		elif "leaves" in short:
			tint = 2
		else:
			tint = 1
	return [tex, 1, tint]


func _first_model(state: Dictionary) -> String:
	if state.has("variants"):
		var v = state["variants"].values()[0]
		if v is Array:
			v = v[0]
		return v.get("model", "")
	if state.has("multipart"):
		for part in state["multipart"]:
			var a = part.get("apply")
			if a is Array:
				a = a[0]
			if a is Dictionary and a.has("model"):
				return a["model"]
	return ""


## {"textures", "elements", "builtin"} with parents resolved, null when the model does not exist
func _load_model(ref: String) -> Variant:
	ref = _strip_ns(ref)
	if _model_cache.has(ref):
		return _model_cache[ref]
	var m = _json("assets/minecraft/models/%s.json" % ref)
	_model_cache[ref] = null
	if m == null:
		return null
	var textures := {}
	var elements = m.get("elements")
	var builtin := false
	var parent = m.get("parent")
	if parent != null:
		if _strip_ns(parent).begins_with("builtin/"):
			builtin = true
		else:
			var p = _load_model(parent)
			if p != null:
				textures = p["textures"].duplicate()
				builtin = p["builtin"]
				if elements == null:
					elements = p["elements"]
	textures.merge(m.get("textures", {}), true)
	var out := {"textures": textures, "elements": elements if elements != null else [], "builtin": builtin}
	_model_cache[ref] = out
	return out


## [texture ref, tintindex or null] of the highest element with a large upward face, else []
func _top_face(model: Dictionary) -> Array:
	var best_key := Vector2(-INF, -INF)
	var best_up = null
	for e in model["elements"]:
		var up = e.get("faces", {}).get("up")
		if up == null:
			continue
		var f: Array = e["from"]
		var t: Array = e["to"]
		var area := absf(t[0] - f[0]) * absf(t[2] - f[2])
		var angle := float(e.get("rotation", {}).get("angle", 0))  # Array.has() does not equate 0.0 with 0
		if area < 64 or not (angle in [0.0, 90.0, 180.0, 270.0]):
			continue
		var key := Vector2(t[1], area)
		if best_up == null or key.x > best_key.x or (key.x == best_key.x and key.y > best_key.y):
			best_key = key
			best_up = up
	if best_up == null:
		return []
	return [_resolve_tex(model["textures"], best_up["texture"]), best_up.get("tintindex")]


## 26.x texture entries may be objects: {"sprite": "minecraft:block/glass", "force_translucent": true}
func _resolve_tex(textures: Dictionary, ref: Variant) -> String:
	var seen := 0
	while seen < 16:
		if ref is Dictionary:
			ref = ref.get("sprite")
		if ref is String and ref.begins_with("#"):
			ref = textures.get(ref.substr(1))
			seen += 1
			continue
		break
	return ref if ref is String and not ref.begins_with("#") else ""


func _atlas_add(ref: String) -> int:
	ref = _strip_ns(ref)
	if _atlas_index.has(ref):
		return _atlas_index[ref]
	var path := "assets/minecraft/textures/%s.png" % ref
	if not _jar.has(path):
		return -1
	_atlas_index[ref] = _atlas_names.size()
	_atlas_names.append(ref)
	_atlas.append_array(_resample4(_load_rgba(_jar.read(path))))
	return _atlas_index[ref]


static func _load_rgba(png: PackedByteArray) -> Image:
	var img := Image.new()
	img.load_png_from_buffer(png)
	img.convert(Image.FORMAT_RGBA8)
	return img


## 16x16 (nearest if the texture is another size, first frame of strips) box-resampled to 4x4, alpha weighted
static func _resample4(img: Image) -> PackedByteArray:
	var w := img.get_width()
	if img.get_height() > w:
		img = img.get_region(Rect2i(0, 0, w, w))
	var px := img.get_data()
	if w != TEX:
		var n := PackedByteArray()
		n.resize(TEX * TEX * 4)
		for y in TEX:
			for x in TEX:
				var sx := int((x + 0.5) * w / float(TEX))
				var sy := int((y + 0.5) * w / float(TEX))
				for c in 4:
					n[(y * TEX + x) * 4 + c] = px[(sy * w + sx) * 4 + c]
		px = n
		w = TEX
	return _box(px, TEX, S)


## alpha-weighted box filter of a size x size RGBA image down to out x out
static func _box(px: PackedByteArray, size: int, out_size: int) -> PackedByteArray:
	var r := size / out_size
	var out := PackedByteArray()
	for y in out_size:
		for x in out_size:
			var sr := 0
			var sg := 0
			var sb := 0
			var sa := 0
			for yy in r:
				for xx in r:
					var o := ((y * r + yy) * size + x * r + xx) * 4
					var a := px[o + 3]
					sr += px[o] * a
					sg += px[o + 1] * a
					sb += px[o + 2] * a
					sa += a
			var d := maxi(sa, 1)
			out.append_array([sr / d, sg / d, sb / d, sa / (r * r)])
	return out


## 16x16 RGBA of the first frame, empty when the texture is wider than tall (Dynmap-GPU assets.rs decode_png_16)
static func _decode16(png: PackedByteArray) -> PackedByteArray:
	var img := _load_rgba(png)
	var w := img.get_width()
	if w == 0 or img.get_height() < w:
		return PackedByteArray()
	var px := img.get_data()
	if w == TEX:
		return px.slice(0, TEX * TEX * 4)
	if w % TEX == 0:
		return _box(px, w, TEX)  # the first w rows are the frame; later rows of a strip are further frames
	var out := PackedByteArray()
	out.resize(TEX * TEX * 4)
	for y in TEX:
		for x in TEX:
			var sx := x * w / TEX
			var sy := y * w / TEX
			for c in 4:
				out[(y * TEX + x) * 4 + c] = px[(sy * w + sx) * 4 + c]
	return out



# --- biomes -----------------------------------------------------------------------------------------------------


func _biomes() -> Dictionary:
	var grass_map := _load_rgba(_jar.read("assets/minecraft/textures/colormap/grass.png"))
	var fol_map := _load_rgba(_jar.read("assets/minecraft/textures/colormap/foliage.png"))
	var out := {}
	var prefix := "data/minecraft/worldgen/biome/"
	for n in _names:
		if not (n.begins_with(prefix) and n.ends_with(".json")):
			continue
		var short := n.substr(prefix.length(), n.length() - prefix.length() - 5)
		var j = _json(n)
		var temp = _find_key(j, "temperature")
		var down = _find_key(j, "downfall")
		temp = 0.8 if temp == null else float(temp)
		down = 0.4 if down == null else float(down)
		var g = _parse_color(_find_key(j, "grass_color"))
		var f = _parse_color(_find_key(j, "foliage_color"))
		var w = _parse_color(_find_key(j, "water_color"))
		w = 0x3F76E4 if w == null else w
		var modifier = _find_key(j, "grass_color_modifier")
		if modifier == null:
			modifier = ""
		var grass: int = g if g != null else _colormap_at(grass_map, temp, down)
		if g == null or modifier == "dark_forest":
			if modifier == "dark_forest":
				grass = ((grass & 0xFEFEFE) + 0x28340A) >> 1
			elif modifier == "swamp":
				grass = 0x6A7039
		var fol: int = f if f != null else _colormap_at(fol_map, temp, down)
		out["minecraft:" + short] = [grass, fol, w]
	return out


static func _colormap_at(img: Image, temp: float, down: float) -> int:
	var t := clampf(temp, 0.0, 1.0)
	var d := clampf(down, 0.0, 1.0) * t
	var w := img.get_width()
	var x := mini(int((1.0 - t) * 255.0), w - 1)
	var y := mini(int((1.0 - d) * 255.0), w - 1)
	var c := img.get_pixel(x, y)
	return (c.r8 << 16) | (c.g8 << 8) | c.b8


static func _find_key(v: Variant, key: String) -> Variant:
	if v is Dictionary:
		if v.has(key):
			return v[key]
		for c in v.values():
			var r = _find_key(c, key)
			if r != null:
				return r
	elif v is Array:
		for c in v:
			var r = _find_key(c, key)
			if r != null:
				return r
	return null


static func _parse_color(v: Variant) -> Variant:
	if v is int or v is float:
		return int(v) & 0xFFFFFF
	if v is String:
		return ("0x" + v.lstrip("#")).hex_to_int()
	return null
