class_name RendererMain
extends SceneTree
## Single entry point of the renderer. Run under a display driver (the GPU needs one, see docker/entrypoint.sh):
##   godot --path . -- <command> [options]
## project.godot names this class in application/run/main_loop_type, because the release export template the
## image runs ignores -s. With the editor binary, `-s scripts/main.gd` works as well.
##
##   render      render tile rectangles to PNG/WebP files (debugging, comparison with reference images)
##   scan        world scan cache (cx, cz, min_y, max_y per chunk)
##   run         whole-map job: plan, render and upload one map, then rebuild its zoom levels
##   watch       resident updater: keeps every map of a config current around the chunks the server saves
##   zoom        rebuild zoom-out levels without rendering
##   build-data  extract blocks, models, textures and biomes from a Minecraft client jar
##   dev         debugging helpers (dump, column, topblocks, colblocks, encodetest, zoomtest)
##
## Options are `--key value` or `--flag`; see each command's class for the full list.


func _initialize() -> void:
	Engine.max_fps = 20  # nothing is drawn; the loop only serves timers, the display connection and the live feed
	var args := Args.parse(OS.get_cmdline_user_args())
	var code := 2
	match args.command:
		"render":
			code = RenderCmd.run(args)
		"scan":
			code = JobCmds.scan(args)
		"run":
			code = await JobCmds.run(args)
		"watch":
			code = await JobCmds.watch(args)
		"zoom":
			code = await JobCmds.zoom(args)
		"build-data":
			code = BuildData.run(args)
		"dev":
			code = DevCmd.run(args)
		_:
			print("usage: main.gd -- render|scan|run|watch|zoom|build-data|dev [options]")
	quit(code)
