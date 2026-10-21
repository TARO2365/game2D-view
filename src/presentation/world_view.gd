class_name WorldView
extends Node2D
## Visual streaming of terrain (spec §2): one TileMapLayer per chunk near the
## camera, pooled and recycled. Only presentation — WorldGrid stays the single
## source of truth and is never modified here.

const MARGIN_CHUNKS := 1
const SKY_COLOR := Color(0.17, 0.14, 0.22)
const BACKWALL_COLOR := Color(0.1, 0.08, 0.07)
## Sky image scale and how many tiles below the average surface its bottom sits.
const SKY_SCALE := 1.5
const SKY_HORIZON_TILES := 1.0

var grid: WorldGrid
var tile_px := 64
## Number of chunk redraws caused by terrain edits (tests / HUD).
var redraw_count := 0

var _tileset: TileSet
var _layers: Dictionary = {}  # Vector2i chunk -> TileMapLayer
var _pool: Array[TileMapLayer] = []
var _range := Rect2i()


func setup(world_grid: WorldGrid, px: int) -> void:
	grid = world_grid
	tile_px = px


func _ready() -> void:
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED  # backwall strip tiles
	_tileset = PlaceholderTiles.build_tileset(grid.registry, tile_px)
	grid.tiles_changed.connect(_on_tiles_changed)
	queue_redraw()


## Production art (ASSET_SPEC §5.2/5.3) when present; flat colours otherwise.
func _draw() -> void:
	var world := Rect2(Vector2.ZERO, Vector2(grid.get_size() * tile_px))
	var wall := backwall_texture()
	if wall != null:
		# 256x64 strip of 4 variants, repeated; scaled so one cell = one tile.
		var s := float(tile_px) / float(wall.get_height())
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE * s)
		draw_texture_rect(wall, Rect2(Vector2.ZERO, world.size / s), true)
		draw_set_transform(Vector2.ZERO)
	else:
		draw_rect(world, BACKWALL_COLOR)
	for x in grid.width:
		draw_rect(Rect2(x * tile_px, 0, tile_px, grid.surface_y[x] * tile_px), SKY_COLOR)
	var sky := sky_texture()
	if sky != null:
		_draw_sky(sky)


func backwall_texture() -> Texture2D:
	return ArtLibrary.texture(ArtLibrary.background_path(&"backwall_dug"))


func sky_texture() -> Texture2D:
	return ArtLibrary.texture(ArtLibrary.background_path(&"sky_surface"))


## Sky image behind the surface; each column is clipped at its own surface line.
func _draw_sky(sky: Texture2D) -> void:
	var size := sky.get_size()
	# The image (scaled by SKY_SCALE) sits with its horizon on the average
	# surface line, repeated horizontally. Above it, its top row is stretched
	# up to the world top; below it, its bottom row continues down to each
	# column's surface — so there is never a flat band or a hard edge.
	var sum := 0
	for x in grid.width:
		sum += grid.surface_y[x]
	var anchor := (float(sum) / grid.width + SKY_HORIZON_TILES) * tile_px
	var s := SKY_SCALE
	var top := anchor - size.y * s
	var tile_w := size.x * s
	for x in grid.width:
		var x0 := float(x * tile_px)
		var y1 := float(grid.surface_y[x] * tile_px)
		if y1 <= 0.0:
			continue
		var sx := fposmod(x0, tile_w)
		var w := minf(float(tile_px), tile_w - sx)
		_sky_column(sky, Rect2(x0, 0.0, w, y1), sx / s, top, s)
		if w < tile_px:
			_sky_column(sky, Rect2(x0 + w, 0.0, tile_px - w, y1), 0.0, top, s)


func _sky_column(sky: Texture2D, dst: Rect2, src_x: float, top: float, s: float) -> void:
	var h := sky.get_size().y
	var sw := dst.size.x / s
	var y0 := dst.position.y
	var y1 := dst.end.y
	if y0 < top:  # above the image: stretch its top row
		draw_texture_rect_region(sky, Rect2(dst.position.x, y0, dst.size.x, minf(top, y1) - y0), Rect2(src_x, 0.0, sw, 1.0))
	var a := maxf(y0, top)
	var b := minf(y1, top + h * s)
	if b > a:
		draw_texture_rect_region(sky, Rect2(dst.position.x, a, dst.size.x, b - a), Rect2(src_x, (a - top) / s, sw, (b - a) / s))
	if y1 > top + h * s:  # below the image: stretch its bottom row
		var c := maxf(y0, top + h * s)
		draw_texture_rect_region(sky, Rect2(dst.position.x, c, dst.size.x, y1 - c), Rect2(src_x, h - 1.0, sw, 1.0))


func loaded_chunk_count() -> int:
	return _layers.size()


func get_chunk_layer(c: Vector2i) -> TileMapLayer:
	return _layers.get(c)


## Call with the camera's visible rect (world pixels).
func update_visible(view: Rect2) -> void:
	var cs := float(WorldGrid.CHUNK_SIZE * tile_px)
	var max_c := Vector2i(grid.chunks_x() - 1, grid.chunks_y() - 1)
	var c0 := (Vector2i(floori(view.position.x / cs), floori(view.position.y / cs))
			- Vector2i.ONE * MARGIN_CHUNKS).clamp(Vector2i.ZERO, max_c)
	var c1 := (Vector2i(floori(view.end.x / cs), floori(view.end.y / cs))
			+ Vector2i.ONE * MARGIN_CHUNKS).clamp(Vector2i.ZERO, max_c)
	var r := Rect2i(c0, c1 - c0 + Vector2i.ONE)
	if r == _range:
		return
	_range = r
	for c in _layers.keys():
		if not r.has_point(c):
			_release(c)
	for cy in range(r.position.y, r.end.y):
		for cx in range(r.position.x, r.end.x):
			var c := Vector2i(cx, cy)
			if not _layers.has(c):
				_load_chunk(c)


func _load_chunk(c: Vector2i) -> void:
	var layer: TileMapLayer
	if _pool.is_empty():
		layer = TileMapLayer.new()
		layer.tile_set = _tileset
		layer.texture_repeat = CanvasItem.TEXTURE_REPEAT_DISABLED  # not inherited from the backwall
		add_child(layer)
	else:
		layer = _pool.pop_back()
		layer.visible = true
	layer.position = Vector2(c * WorldGrid.CHUNK_SIZE * tile_px)
	layer.clear()
	_fill(layer, c, grid.chunk_rect(c))
	_layers[c] = layer


func _release(c: Vector2i) -> void:
	var layer: TileMapLayer = _layers[c]
	_layers.erase(c)
	layer.clear()
	layer.visible = false
	_pool.append(layer)


func _fill(layer: TileMapLayer, c: Vector2i, rect: Rect2i) -> void:
	var t := grid.tiles
	var st := grid.structures
	var origin := c * WorldGrid.CHUNK_SIZE
	for y in range(rect.position.y, rect.end.y):
		var row := y * grid.width
		for x in range(rect.position.x, rect.end.x):
			var id: int = t[row + x]
			var local := Vector2i(x, y) - origin
			if id != TileRegistry.AIR:
				layer.set_cell(local, PlaceholderTiles.TERRAIN_SOURCE, Vector2i(id, 0))
			elif st[row + x] != WorldGrid.Structure.NONE:
				layer.set_cell(local, PlaceholderTiles.STRUCTURE_SOURCE, Vector2i(st[row + x], 0))
			else:
				layer.erase_cell(local)


func _on_tiles_changed(rect: Rect2i) -> void:
	for c in grid.chunks_in_rect(rect):
		if _layers.has(c):
			_fill(_layers[c], c, rect.intersection(grid.chunk_rect(c)))
			redraw_count += 1
