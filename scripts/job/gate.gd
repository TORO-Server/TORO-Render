class_name Gate
extends RefCounted
## When rendering may run next to a live game server: the 1-minute load stays below a limit and, optionally, nobody is
## playing. Presence comes from the live player feed and/or a file "<online> <unix time>" written by the proxy; a missing
## or stale file, or a feed that is not connected, counts as busy.

var max_load := 4.0
## < 0: ignore players; otherwise busy while more than this many are online
var max_players := -1
var online_file := ""
var stale_after := 120
var feed: LiveFeed
var poll_seconds := 30.0


## "" when rendering may proceed, else why not.
func reason() -> String:
	var load1 := Term.load1()
	if load1 > max_load:
		return "load1=%.2f" % load1
	if max_players < 0:
		return ""
	if online_file != "":
		var f := FileAccess.open(online_file, FileAccess.READ)
		var parts := f.get_as_text().split(" ", false) if f != null else PackedStringArray()
		if parts.size() < 2 or Time.get_unix_time_from_system() - parts[1].to_int() > stale_after:
			return "online file unreadable or stale"
		if parts[0].to_int() > max_players:
			return "online=%s" % parts[0]
	if feed != null:
		if not feed.healthy():
			return "player feed not connected"
		if feed.count() > max_players:
			return "%d players visible" % feed.count()
	return ""


## Blocks (without freezing the main loop) until rendering may proceed. Use with `await`.
func wait_quiet() -> void:
	var announced := false
	while true:
		var why := reason()
		if why == "":
			if announced:
				Term.say("quiet again, resuming")
			return
		if not announced:
			Term.say("waiting: " + why)
			announced = true
		await Term.sleep(poll_seconds)
