class_name DirtyFeed
extends RefCounted
## Receives block-change events from the game server (TORO-Core's map-dirty module) over one WebSocket.
## The game server connects here and shows the shared token in a first {"t":"auth","token":...} message --
## Godot's WebSocket server cannot read the handshake headers, so the token cannot travel in one the way
## dynmap-live sends it to the map site; the style (one socket, one shared token, reconnect with backoff on
## the sender side) is the same. Until a connection is authenticated its messages are dropped.
##
## After that the server sends {"t":"dirty","worlds":{"<world>":{"bukkit":[[cx,cz],...],"worldedit":[...]}}}
## once per debounce window. Chunks wait here, per world, until the watch drains them into its pending queue;
## nothing is rendered from this class.

const MAX_CLIENTS := 8
const MAX_WORLDS := 64
const MAX_CHUNKS_PER_MESSAGE := 1_000_000
const AUTH_MSEC := 10_000

var _server := TCPServer.new()
var _token := ""
var _clients: Array = []  # {peer: WebSocketPeer, authed: bool, deadline: int (ticks msec)}
var _queue := {}  # world -> {Vector2i: true}
var _connected := false


## Starts listening. Returns false (and never listens) without a token or when the port is taken.
func start(port: int, token: String) -> bool:
	if port <= 0 or token == "":
		return false
	if _server.listen(port) != OK:
		push_warning("dirty feed: cannot listen on port %d" % port)
		return false
	_token = token
	_connected = true
	(Engine.get_main_loop() as SceneTree).process_frame.connect(poll)
	Term.say("dirty feed listening on port %d" % port)
	return true


func stop() -> void:
	if _connected:
		(Engine.get_main_loop() as SceneTree).process_frame.disconnect(poll)
		_connected = false
	for c in _clients:
		(c["peer"] as WebSocketPeer).close()
	_clients.clear()
	_server.stop()


## Accepts connections and reads messages. Runs every frame of the main loop while started.
func poll() -> void:
	while _server.is_connection_available() and _clients.size() < MAX_CLIENTS:
		var peer := WebSocketPeer.new()
		if peer.accept_stream(_server.take_connection()) != OK:
			continue
		_clients.append({"peer": peer, "authed": false, "deadline": Time.get_ticks_msec() + AUTH_MSEC})
	var now := Time.get_ticks_msec()
	var alive: Array = []
	for c in _clients:
		var peer: WebSocketPeer = c["peer"]
		peer.poll()
		match peer.get_ready_state():
			WebSocketPeer.STATE_OPEN:
				while peer.get_available_packet_count() > 0:
					_message(c, peer.get_packet().get_string_from_utf8())
				alive.append(c)
			WebSocketPeer.STATE_CONNECTING:
				if not c["authed"] and now > int(c["deadline"]):
					peer.close()
				else:
					alive.append(c)
			WebSocketPeer.STATE_CLOSING:
				alive.append(c)
	_clients = alive


func _message(c: Dictionary, text: String) -> void:
	var msg = JSON.parse_string(text)
	if not (msg is Dictionary):
		return
	if not c["authed"]:
		if msg.get("t") is String and msg["t"] == "auth" and msg.get("token") is String and msg["token"] == _token:
			c["authed"] = true
		else:
			(c["peer"] as WebSocketPeer).close()
		return
	if msg.get("t") is String and msg["t"] == "dirty":
		var parsed := parse_dirty(msg)
		for world: String in parsed:
			if not _queue.has(world):
				_queue[world] = {}
			var seen: Dictionary = _queue[world]
			for chunk in parsed[world]:
				seen[chunk] = true


## The chunks of one dirty message: world -> Array[Vector2i]. Bad entries are dropped, and a message is
## capped so a broken or hostile sender cannot grow the queue without bound.
static func parse_dirty(msg: Dictionary) -> Dictionary:
	var out := {}
	var worlds = msg.get("worlds")
	if not (worlds is Dictionary):
		return out
	var total := 0
	for world: String in worlds:
		if out.size() >= MAX_WORLDS:
			break
		var by_source = worlds[world]
		if not (by_source is Dictionary):
			continue
		var chunks: Array = []
		var seen := {}
		for source: String in by_source:
			var list = by_source[source]
			if not (list is Array):
				continue
			for e in list:
				if not (e is Array) or e.size() != 2 or not _coord(e[0]) or not _coord(e[1]):
					continue
				var chunk := Vector2i(int(e[0]), int(e[1]))
				if seen.has(chunk):
					continue
				seen[chunk] = true
				chunks.append(chunk)
				total += 1
				if total >= MAX_CHUNKS_PER_MESSAGE:
					break
			if total >= MAX_CHUNKS_PER_MESSAGE:
				break
		if not chunks.is_empty():
			out[world] = chunks
		if total >= MAX_CHUNKS_PER_MESSAGE:
			break
	return out


static func _coord(v: Variant) -> bool:
	return v is int or (v is float and is_finite(v) and v == floorf(v))


## All received chunks so far: world -> Array[Vector2i]. Empties the queue.
func drain() -> Dictionary:
	var out := {}
	for world: String in _queue:
		var chunks: Array = []
		chunks.assign((_queue[world] as Dictionary).keys())
		out[world] = chunks
	_queue.clear()
	return out


func queued() -> int:
	var n := 0
	for world: String in _queue:
		n += (_queue[world] as Dictionary).size()
	return n


## Connections that completed the token check.
func authenticated() -> int:
	var n := 0
	for c in _clients:
		if c["authed"]:
			n += 1
	return n
