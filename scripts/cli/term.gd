class_name Term
extends RefCounted
## Console output and waiting for the long-running commands.


static func say(msg: String) -> void:
	print("%s %s" % [Time.get_datetime_string_from_system(false, true), msg])


## Waits without freezing the main loop, so display events and the live feed keep being served. Use with `await`.
static func sleep(seconds: float) -> void:
	await (Engine.get_main_loop() as SceneTree).create_timer(seconds).timeout


static func load1() -> float:
	var f := FileAccess.open("/proc/loadavg", FileAccess.READ)  # absent on Windows
	if f == null:
		return 0.0
	return f.get_as_text().split(" ")[0].to_float()
