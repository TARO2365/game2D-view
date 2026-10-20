class_name RoomOverlay
extends Node2D
## Toggleable tint of every detected room by type, with the type name at the
## room's centre (M3 plan item 8). Reads RoomMap; never mutates.

const TYPE_COLORS := {  # PLACEHOLDER palette
	&"bedroom": Color(0.55, 0.45, 1.0, 0.3),
	&"storage": Color(1.0, 0.75, 0.25, 0.3),
	&"dining": Color(0.35, 0.9, 0.55, 0.3),
	&"room": Color(0.75, 0.75, 0.8, 0.22),
}
const TYPE_NAMES := {&"bedroom": "Bedroom", &"storage": "Storage room", &"dining": "Dining room", &"room": "Room"}
const LABEL_FONT_SIZE := 22

var rooms: RoomMap
var tile_px := 64
## Room type names drawn in the last redraw (tests).
var drawn_labels: Array[String] = []

var _visible_tiles := Rect2i()


func setup(room_map: RoomMap, px: int) -> void:
	rooms = room_map
	tile_px = px
	visible = false
	rooms.rooms_changed.connect(func(_r: Rect2i) -> void: queue_redraw())
	visibility_changed.connect(queue_redraw)


func set_visible_rect(view: Rect2) -> void:
	var r := Rect2i(Vector2i((view.position / tile_px).floor()) - Vector2i.ONE,
			Vector2i((view.size / tile_px).ceil()) + Vector2i.ONE * 3)
	if r != _visible_tiles:
		_visible_tiles = r
		if visible:
			queue_redraw()


static func type_name(type: StringName) -> String:
	return TYPE_NAMES.get(type, String(type).capitalize())


## "Bedroom, 12 tiles" for the HUD, "" when tile is in no room.
static func describe(room: Dictionary) -> String:
	if room.is_empty():
		return ""
	return "%s, %d tiles" % [type_name(room["type"]), room["size"]]


func _draw() -> void:
	drawn_labels.clear()
	if not visible:
		return
	var w := rooms.grid.width
	var font: Font = ThemeDB.fallback_font
	for room in rooms.all_rooms():
		var b: Rect2i = room["bounds"]
		if not _visible_tiles.intersects(b):
			continue
		var col: Color = TYPE_COLORS.get(room["type"], TYPE_COLORS[&"room"])
		for idx in rooms.room_tiles(room["id"]):
			draw_rect(Rect2(Vector2(idx % w, idx / w) * tile_px, Vector2.ONE * tile_px), col)
		var text := type_name(room["type"])
		drawn_labels.append(text)
		var centre := (Vector2(b.position) + Vector2(b.size) / 2.0) * tile_px
		var width := maxf(b.size.x * tile_px, 200.0)
		var pos := Vector2(centre.x - width / 2.0, centre.y + LABEL_FONT_SIZE * 0.35)
		draw_string_outline(font, pos, text, HORIZONTAL_ALIGNMENT_CENTER, width, LABEL_FONT_SIZE, 5, Color.BLACK)
		draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_CENTER, width, LABEL_FONT_SIZE, Color(col, 1.0).lightened(0.4))
