extends SceneTree
## Feasibility probe for an isometric (iso_SE_30) view: builds a block mesh from a region, renders it with Godot's own
## rasteriser through an orthographic camera into an offscreen SubViewport and saves a PNG.
##   -- --region-dir DIR --origin x,z --size N --out FILE [--data-dir DIR]
## Only cube-like blocks, one flat colour per block (4x4 atlas average) and Lambert shading: it proves the
## rasteriser path (SubViewport + readback) works on the iGPU, not Dynmap-exact output.

func _initialize() -> void:
	var args := {}
	var argv := OS.get_cmdline_user_args()
	for i in range(0, argv.size() - 1, 2):
		args[argv[i].substr(2)] = argv[i + 1]
	var table := BlockTable.new()
	table.load_dir(args.get("data-dir", ProjectSettings.globalize_path("res://data")))
	var world := WorldReader.new(args["region-dir"], table)
	var o := PackedStringArray(String(args.get("origin", "0,0")).split(","))
	var ox := int(o[0])
	var oz := int(o[1])
	var n := int(args.get("size", "64"))

	# average colour per texture
	var avg := PackedColorArray()
	for t in table.tex_count:
		var r := 0
		var g := 0
		var b := 0
		var a := 0
		for i in 16:
			var px: int = t * 64 + i * 4
			var al: int = table.atlas[px + 3]
			r += table.atlas[px] * al
			g += table.atlas[px + 1] * al
			b += table.atlas[px + 2] * al
			a += al
		a = maxi(a, 1)
		avg.append(Color(r / 255.0 / a, g / 255.0 / a, b / 255.0 / a))

	var t0 := Time.get_ticks_usec()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var heights := {}
	var tops := {}
	for dz in n:
		for dx in n:
			var x := ox + dx
			var z := oz + dz
			var c := world.chunk(x >> 4, z >> 4)
			if c == null:
				continue
			for y in range(c.max_y() - 1, c.min_y() - 1, -1):
				var id := c.block(x & 15, y, z & 15)
				if table.kind[id] != BlockTable.KIND_NONE:
					heights[Vector2i(dx, dz)] = y
					tops[Vector2i(dx, dz)] = id
					break
	var quads := 0
	for key in heights:
		var h: int = heights[key]
		var id: int = tops[key]
		var col: Color = avg[table.tex[id]] * Color(1, 1, 1) if table.kind[id] == BlockTable.KIND_SOLID else Color(0.25, 0.45, 0.85)
		var x0 := float(key.x)
		var z0 := float(key.y)
		_quad(st, Vector3(x0, h + 1, z0), Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3.UP, col, 1.0)
		quads += 1
		for side in [[Vector2i(1, 0), Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3.RIGHT, 0.8], [Vector2i(-1, 0), Vector3(0, 0, 0), Vector3(0, 0, 1), Vector3.LEFT, 0.8], \
				[Vector2i(0, 1), Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3.BACK, 0.65], [Vector2i(0, -1), Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3.FORWARD, 0.65]]:
			var nh: int = heights.get(key + side[0], h)
			if nh < h:
				var base: Vector3 = Vector3(x0, nh + 1, z0) + side[1]
				_quad(st, base, side[2], Vector3(0, h - nh, 0), side[3], col, side[4])
				quads += 1
	var mesh := st.commit()
	print("mesh: %d quads in %.0f ms" % [quads, (Time.get_ticks_usec() - t0) / 1000.0])

	var vp := SubViewport.new()
	vp.size = Vector2i(1024, 1024)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	root.add_child(vp)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	vp.add_child(mi)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = n * 1.6
	vp.add_child(cam)
	var center := Vector3(n / 2.0, 64, n / 2.0)
	var dir := Vector3(1, 0, 1).normalized().rotated(Vector3.UP, 0.0)
	dir = (dir * cos(deg_to_rad(30.0)) + Vector3.UP * sin(deg_to_rad(30.0))).normalized()
	cam.far = 1000.0
	cam.look_at_from_position(center + dir * 400.0, center, Vector3.UP)

	var t1 := Time.get_ticks_usec()
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	print("viewport render+readback: %.0f ms, %s" % [(Time.get_ticks_usec() - t1) / 1000.0, RenderingServer.get_current_rendering_driver_name()])
	print("device: ", RenderingServer.get_video_adapter_name())
	img.save_png(args.get("out", "iso.png"))
	quit(0)


func _quad(st: SurfaceTool, origin: Vector3, u: Vector3, v: Vector3, normal: Vector3, col: Color, shade: float) -> void:
	var c := Color(col.r * shade, col.g * shade, col.b * shade)
	var p := [origin, origin + u, origin + u + v, origin + v]
	for i in [0, 1, 2, 0, 2, 3]:
		st.set_color(c)
		st.set_normal(normal)
		st.add_vertex(p[i])
