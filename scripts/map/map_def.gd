class_name MapDef
extends RefCounted
## One Dynmap map: which TiDB MapID it fills, from which region directory, in which perspective.

var id := 0
var region_dir := ""
var persp_name := "iso_S_90_lowres"
var zoom_max := 10
var min_y := -64
var max_y := 320
var mega := 8
## Dynmap world ("main", "flat", "map"): resolved from the database, matches the live player feed
var world := ""


func persp() -> Persp:
	return Persp.by_name(persp_name)


## Config file (JSON), shape in docker/maps.example.json:
##   {"db": {host, port, user, password, database}, "live": "wss://.../up/ws", "maps": [{id, region, persp, zoom_max}]}
static func load_config(path: String) -> Dictionary:
	if path == "":
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("cannot read config %s" % path)
		return {}
	var cfg = JSON.parse_string(f.get_as_text())
	return cfg if cfg is Dictionary else {}


static func from_entry(e: Dictionary) -> MapDef:
	var m := MapDef.new()
	m.id = int(e.get("id", 0))
	m.region_dir = e.get("region", "")
	m.persp_name = e.get("persp", m.persp_name)
	m.zoom_max = int(e.get("zoom_max", m.zoom_max))
	m.min_y = int(e.get("min_y", m.min_y))
	m.max_y = int(e.get("max_y", m.max_y))
	m.mega = int(e.get("mega", m.mega))
	return m


## `--map-id` picks the entry of --config; --region-dir / --persp / --zoom-max / --mega override or replace it.
static func from_args(args: Args, cfg: Dictionary) -> MapDef:
	var m := MapDef.new()
	m.id = args.integer("map-id")
	for e in cfg.get("maps", []):
		if int(e.get("id", 0)) == m.id:
			m = from_entry(e)
	m.region_dir = args.text("region-dir", m.region_dir)
	m.persp_name = args.text("persp", m.persp_name)
	m.zoom_max = args.integer("zoom-max", m.zoom_max)
	m.mega = args.integer("mega", m.mega)
	return m


## database settings: config "db" section, overridden by --db-host / --db-port
static func db_config(args: Args, cfg: Dictionary) -> Dictionary:
	var db: Dictionary = cfg.get("db", {}).duplicate()
	if args.has("db-host"):
		db["host"] = args.text("db-host")
	if args.has("db-port"):
		db["port"] = args.integer("db-port")
	return db
