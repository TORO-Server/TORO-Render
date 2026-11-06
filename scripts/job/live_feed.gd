class_name LiveFeed
extends RefCounted
## Real-time player positions over the map site's WebSocket (/up/ws). A client that sends {"subscribe": "<world>"} gets
## {"type":"players","players":[{account, world, x, y, z, health, armor}, ...]} whenever the positions of the players
## Dynmap shows in that world change, so one connection per watched world. Reconnects on its own.
##
## Only wss:// (certificates are verified), or ws:// to this machine. With any other URL the feed never connects, which
## the gate treats as "not connected" rather than as "nobody online".

const RETRY_MIN_MS := 5_000
const RETRY_MAX_MS := 60_000
const MAX_PLAYERS := 1000

var url := ""
var _worlds := {}  # world -> {"peer", "open", "players", "retry_at", "backoff"}


func _init(url_: String) -> void:
	url = url_
	if not allowed_url(url):
		push_warning("live feed disabled: %s is not a wss:// URL" % url)


static func allowed_url(u: String) -> bool:
	return u.begins_with("wss://") or u.begins_with("ws://127.0.0.1:") or u.begins_with("ws://localhost:")


## Starts following a world; polling happens every frame of the main loop (use Term.sleep to wait).
func watch(world: String) -> void:
	if world == "" or _worlds.has(world) or not allowed_url(url):
		return
	_worlds[world] = {"peer": null, "open": false, "players": [], "retry_at": 0, "backoff": RETRY_MIN_MS}
	if _worlds.size() == 1:
		(Engine.get_main_loop() as SceneTree).process_frame.connect(poll)


func poll() -> void:
	var now := Time.get_ticks_msec()
	for world: String in _worlds:
		var w: Dictionary = _worlds[world]
		var peer: WebSocketPeer = w["peer"]
		if peer == null:
			if now >= w["retry_at"]:
				peer = WebSocketPeer.new()
				if peer.connect_to_url(url) != OK:
					_lost(w, now)
					continue
				w["peer"] = peer
			continue
		peer.poll()
		match peer.get_ready_state():
			WebSocketPeer.STATE_OPEN:
				if not w["open"]:
					w["open"] = true
					w["backoff"] = RETRY_MIN_MS
					peer.send_text(JSON.stringify({"subscribe": world}))
				while peer.get_available_packet_count() > 0:
					_message(w, peer.get_packet().get_string_from_utf8())
			WebSocketPeer.STATE_CLOSED:
				_lost(w, now)


func _lost(w: Dictionary, now: int) -> void:
	w["peer"] = null
	w["open"] = false
	w["players"] = []
	w["retry_at"] = now + w["backoff"]
	w["backoff"] = mini(w["backoff"] * 2, RETRY_MAX_MS)


func _message(w: Dictionary, text: String) -> void:
	var msg = JSON.parse_string(text)
	if msg is Dictionary and msg.get("type") is String and msg["type"] == "players" and msg.get("players") is Array:
		w["players"] = valid_players(msg["players"])


## The entries with usable coordinates (the feed comes from another service).
static func valid_players(list: Array) -> Array:
	var out := []
	for p in list:
		if p is Dictionary and _coord(p.get("x")) and _coord(p.get("y")) and _coord(p.get("z")):
			out.append(p)
			if out.size() >= MAX_PLAYERS:
				break
	return out


static func _coord(v: Variant) -> bool:
	return v is int or (v is float and is_finite(v))


## Players of a world: Array of Dictionary with x, y, z (block coordinates).
func players(world: String) -> Array:
	return _worlds[world]["players"] if _worlds.has(world) else []


func count() -> int:
	var n := 0
	for w: Dictionary in _worlds.values():
		n += w["players"].size()
	return n


## true while every followed world has an open socket
func healthy() -> bool:
	for w: Dictionary in _worlds.values():
		if not w["open"]:
			return false
	return not _worlds.is_empty()
