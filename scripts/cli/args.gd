class_name Args
extends RefCounted
## Command line of `godot -s scripts/main.gd -- <command> [--key value] [--flag]`.
## A token starting with `--` is an option; it takes the next token as its value unless that one is an option too.

var command := ""
var _opts := {}


static func parse(argv: PackedStringArray) -> Args:
	var a := Args.new()
	var i := 0
	if argv.size() > 0 and not argv[0].begins_with("--"):
		a.command = argv[0]
		i = 1
	while i < argv.size():
		var tok := argv[i]
		i += 1
		if not tok.begins_with("--"):
			if not a._opts.has("sub"):  # second positional word: dev dump ...
				a._opts["sub"] = tok
			continue
		var key := tok.substr(2)
		if i < argv.size() and not argv[i].begins_with("--"):
			a._opts[key] = argv[i]
			i += 1
		else:
			a._opts[key] = "1"
	return a


func to_dict() -> Dictionary:
	return _opts.duplicate()


func has(key: String) -> bool:
	return _opts.has(key)


func text(key: String, fallback := "") -> String:
	return _opts.get(key, fallback)


func integer(key: String, fallback := 0) -> int:
	return int(_opts[key]) if _opts.has(key) else fallback


func number(key: String, fallback := 0.0) -> float:
	return float(_opts[key]) if _opts.has(key) else fallback


func flag(key: String) -> bool:
	return _opts.has(key) and _opts[key] != "0"


## "a,b,c" -> ints
func ints(key: String, fallback := PackedInt32Array()) -> PackedInt32Array:
	if not _opts.has(key):
		return fallback
	var out := PackedInt32Array()
	for s in String(_opts[key]).split(",", false):
		out.append(int(s))
	return out
