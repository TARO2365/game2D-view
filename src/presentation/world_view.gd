class_name WorldView
extends Node2D
## Visual streaming of terrain (spec §2): one TileMapLayer per chunk near the
## camera, pooled and recycled. Only presentation — WorldGrid stays the single
## source of truth and is never modified here.

const MARGIN_CHUNKS := 1
const SKY_COLOR := Color(0.17, 0.14, 0.22)
const BACKWALL_COLOR := Color(0.1, 0.08, 0.07)

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
	_tileset = PlaceholderTiles.build_tileset(grid.registry, tile_px)
	grid.tiles_changed.connect(_on_tiles_changed)
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, Vector2(grid.get_size() * tile_px)), BACKWALL_COLOR)
	for x in grid.width:
		draw_rect(Rect2(x * tile_px, 0, tile_px, grid.surface_y[x] * tile_px), SKY_COLOR)


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
