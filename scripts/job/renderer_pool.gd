class_name RendererPool
extends RefCounted
## Everything the GPU side needs, set up once per process: one RenderingDevice, the block models and block table, and
## one IsoRenderer per (perspective, region directory).

var rd: RenderingDevice
var reg: StateRegistry
var table: BlockTable
var device_name := ""
var _renderers := {}


static func create(data_dir: String) -> RendererPool:
	var p := RendererPool.new()
	p.table = BlockTable.new()
	if not p.table.load_dir(data_dir):
		return null
	p.reg = StateRegistry.new()
	if not p.reg.load_dir(data_dir):
		return null
	p.rd = RenderingServer.create_local_rendering_device()
	if p.rd == null:
		push_error("no RenderingDevice (--headless has none: run under a display driver, see docker/entrypoint.sh)")
		return null
	p.device_name = p.rd.get_device_name()
	return p


func renderer(persp_name: String, region_dir: String) -> IsoRenderer:
	var key := persp_name + "|" + region_dir
	if _renderers.has(key):
		return _renderers[key]
	var persp := Persp.by_name(persp_name)
	if persp == null:
		push_error("unknown perspective %s" % persp_name)
		return null
	var iso := IsoRenderer.new()
	iso.rd = rd
	if not iso.setup(persp, reg, table, WorldReader.new(region_dir, table)):
		return null
	_renderers[key] = iso
	return iso


## Renders each mega tile (mega x mega tiles) -> Vector2i -> null (blank) or {"img": Image, "hash": int}.
func render_megas(iso: IsoRenderer, megas: Array[Vector2i], mega: int, min_y: int, max_y: int) -> Dictionary:
	var tiles := {}
	iso.min_y = min_y
	iso.max_y = max_y
	for m in megas:
		iso.next_generation()
		var images := iso.render(m.x * mega, m.y * mega, mega, mega)
		var i := 0
		for ty in mega:
			for tx in mega:
				var img := images[i]
				i += 1
				var data := img.get_data()
				tiles[Vector2i(m.x * mega + tx, m.y * mega + ty)] = null if TileCodec.is_blank(data) else {"img": img, "hash": TileCodec.crc_hash(data)}
	iso.drop_caches()
	return tiles
