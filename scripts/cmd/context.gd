class_name Context
extends RefCounted
## What the database-backed commands (run, watch, zoom) share: config file, tile store, quiet-gate and live player feed.
##
## Common options: --config FILE (default /config/maps.json when present), --db-host/--db-port/--db-user, --rate BYTES/S,
## --dry-run, --live URL (WebSocket of the map site, default from the config; --live off disables), --max-load N,
## --max-players N (< 0 ignores players), --online-file FILE, --stale-after S.

var args: Args
var cfg := {}
var store := TileStore.new()
var gate := Gate.new()
var feed: LiveFeed


static func create(args_: Args, default_max_load: float, default_max_players: int) -> Context:
	var c := Context.new()
	c.args = args_
	var cfg_path := args_.text("config", "/config/maps.json" if FileAccess.file_exists("/config/maps.json") else "")
	c.cfg = MapDef.load_config(cfg_path)
	var db := MapDef.db_config(args_, c.cfg)
	if db.get("password", "") == "" and not db.has("error"):
		Term.say("warning: no database password configured (DYNMAP_DB_PASSWORD or password_file)")
	c.store.configure(db)
	c.store.rate = args_.number("rate", 8_000_000.0)
	c.store.dry_run = args_.flag("dry-run")
	c.gate.max_load = args_.number("max-load", default_max_load)
	c.gate.max_players = args_.integer("max-players", default_max_players)
	c.gate.online_file = args_.text("online-file")
	c.gate.stale_after = args_.integer("stale-after", 120)
	c.gate.poll_seconds = args_.number("poll", 30.0)
	var live := args_.text("live", c.cfg.get("live", ""))
	if live != "" and live != "off":
		c.feed = LiveFeed.new(live)
		c.gate.feed = c.feed
	return c


## Opens the database and starts following the map's world on the live feed.
func attach(map: MapDef) -> bool:
	store.map_id = map.id
	if not store.connect_db():
		Term.say("database unreachable: " + store.error)
		return false
	map.world = store.world_name()
	if feed != null:
		feed.watch(map.world)
	return true
