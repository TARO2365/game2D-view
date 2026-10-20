class_name DesignationOverlay
extends Node2D
## Draws player orders (dig / build wall) on top of terrain, visible area only.

const DIG_FILL := Color(1.0, 0.62, 0.15, 0.3)
const DIG_EDGE := Color(1.0, 0.7, 0.2, 0.9)
const BUILD_FILL := Color(0.3, 0.8, 1.0, 0.3)
const BUILD_EDGE := Color(0.4, 0.85, 1.0, 0.9)

var designations: DesignationMap
var tile_px := 64
var _visible_tiles := Rect2i()


func setup(map: DesignationMap, px: int) -> void:
	designations = map
	tile_px = px
	designations.designations_changed.connect(func(_r: Rect2i) -> void: queue_redraw())


func set_visible_rect(view: Rect2) -> void:
	var r := Rect2i(Vector2i((view.position / tile_px).floor()) - Vector2i.ONE,
			Vector2i((view.size / tile_px).ceil()) + Vector2i.ONE * 3)
	if r != _visible_tiles:
		_visible_tiles = r
		queue_redraw()


func _draw() -> void:
	var w := designations.grid.width
	var entries := designations.entries()
	for idx in entries:
		var p := Vector2i(idx % w, idx / w)
		if not _visible_tiles.has_point(p):
			continue
		var rect := Rect2(Vector2(p * tile_px) + Vector2(3, 3), Vector2(tile_px - 6, tile_px - 6))
		var dig: bool = entries[idx] == DesignationMap.Kind.DIG
		draw_rect(rect, DIG_FILL if dig else BUILD_FILL)
		draw_rect(rect, DIG_EDGE if dig else BUILD_EDGE, false, 2.0)
