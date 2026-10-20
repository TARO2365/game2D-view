class_name NpcView
extends Node2D
## Placeholder body of one colonist (flat shapes, obviously not final art).
## Node origin = bottom-centre of the feet tile (D-003 pivot). Reads the Npc
## and Inventory every frame (Colony does not emit per tick); never mutates.

const BODY_WIDTH_TILES := 0.6     # PLACEHOLDER (D-003: ~2.5-tile sprite)
const BODY_HEIGHT_TILES := 2.5    # PLACEHOLDER
const HEAD_RADIUS_TILES := 0.22   # PLACEHOLDER
const CARRY_SIZE_TILES := 0.32    # PLACEHOLDER
const BAR_WIDTH_TILES := 0.8      # PLACEHOLDER
const BAR_HEIGHT_PX := 6.0
const LABEL_WIDTH_PX := 240.0
const LABEL_FONT_SIZE := 18       # PLACEHOLDER
## Visual smoothing toward the interpolated tick position (1/s). PLACEHOLDER.
const SMOOTH_RATE := 18.0
## Farther than this (tiles) the view snaps instead of sliding (load, teleport).
const SNAP_TILES := 3.0
const SKIN_COLOR := Color(0.93, 0.78, 0.62)
const OUTLINE_COLOR := Color(0.05, 0.04, 0.04)
const SELECT_COLOR := Color(1.0, 0.92, 0.25)
const BAR_BG := Color(0, 0, 0, 0.7)
const BAR_FG := Color(0.35, 0.95, 0.4)

var npc: Npc
var inventory: Inventory
var registry: TileRegistry
var tile_px := 64
var selected := false:
	set(v):
		if v != selected:
			selected = v
			queue_redraw()
var label: Label

var _color := Color.WHITE
var _draw_key := ""


func setup(n: Npc, inv: Inventory, reg: TileRegistry, px: int) -> void:
	npc = n
	inventory = inv
	registry = reg
	tile_px = px
	_color = color_for_id(n.id)


func _ready() -> void:
	label = Label.new()
	label.name = "Nickname"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", LABEL_FONT_SIZE)
	label.add_theme_constant_override("outline_size", 5)
	label.add_theme_color_override("font_outline_color", OUTLINE_COLOR)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.size = Vector2(LABEL_WIDTH_PX, LABEL_FONT_SIZE + 10)
	label.position = Vector2(-LABEL_WIDTH_PX / 2.0, -BODY_HEIGHT_TILES * tile_px - LABEL_FONT_SIZE - 26)
	add_child(label)
	position = target_position()
	sync()


func _process(delta: float) -> void:
	position = smooth_toward(position, target_position(), delta, SMOOTH_RATE, SNAP_TILES * tile_px)
	sync()


## Pulls the NPC fields that affect drawing; redraws only when they change.
func sync() -> void:
	if label.text != npc.nickname:
		label.text = npc.nickname
	var carried := inventory.carried_by(npc.id)
	var key := "%s|%d|%s" % [carried.material if carried else &"", roundi(npc.work_progress * 50.0), npc.state]
	if key != _draw_key:
		_draw_key = key
		queue_redraw()


func target_position() -> Vector2:
	return feet_position(npc.prev_tile, npc.tile, npc.move_progress, tile_px)


func _draw() -> void:
	var px := float(tile_px)
	var w := BODY_WIDTH_TILES * px
	var h := BODY_HEIGHT_TILES * px
	var r := HEAD_RADIUS_TILES * px
	var torso_top := -h + 2.0 * r
	if selected:
		draw_rect(Rect2(-w / 2.0 - 6.0, -h - 6.0, w + 12.0, h + 10.0), SELECT_COLOR, false, 3.0)
		draw_set_transform(Vector2(0, -2), 0.0, Vector2(1.0, 0.3))
		draw_arc(Vector2.ZERO, w * 0.9, 0.0, TAU, 32, SELECT_COLOR, 4.0)
		draw_set_transform(Vector2.ZERO)
	# Legs (darker) and torso (NPC colour).
	var legs_top := -h * 0.4
	draw_rect(Rect2(-w / 2.0, legs_top, w, -legs_top), _color.darkened(0.45))
	draw_rect(Rect2(-w / 2.0, torso_top, w, legs_top - torso_top), _color)
	draw_rect(Rect2(-w / 2.0, torso_top, w, -torso_top), OUTLINE_COLOR, false, 2.0)
	draw_line(Vector2(0, legs_top + 4.0), Vector2(0, 0), OUTLINE_COLOR, 2.0)
	# Head.
	draw_circle(Vector2(0, -h + r), r, SKIN_COLOR)
	draw_arc(Vector2(0, -h + r), r, 0.0, TAU, 24, OUTLINE_COLOR, 2.0)
	# Carried material: small square held in front of the chest.
	var carried := inventory.carried_by(npc.id)
	if carried != null:
		var s := CARRY_SIZE_TILES * px
		var box := Rect2(w / 2.0 - s * 0.4, -h * 0.62, s, s)
		draw_rect(box, material_color(registry, carried.material))
		draw_rect(box, OUTLINE_COLOR, false, 2.0)
	# Work progress bar above the head.
	if npc.state == &"working" or npc.work_progress > 0.0:
		var bw := BAR_WIDTH_TILES * px
		var bar := Rect2(-bw / 2.0, -h - BAR_HEIGHT_PX - 6.0, bw, BAR_HEIGHT_PX)
		draw_rect(bar, BAR_BG)
		draw_rect(Rect2(bar.position, Vector2(bw * clampf(npc.work_progress, 0.0, 1.0), BAR_HEIGHT_PX)), BAR_FG)


# --- Pure helpers (unit tested) -------------------------------------------

## Bottom-centre of the feet tile, interpolated along the current step.
static func feet_position(prev: Vector2i, tile: Vector2i, progress: float, px: int) -> Vector2:
	var t := clampf(progress, 0.0, 1.0)
	var p := Vector2(prev).lerp(Vector2(tile), t)
	return Vector2((p.x + 0.5) * px, (p.y + 1.0) * px)


## Frame-rate independent exponential approach; snaps on large jumps.
static func smooth_toward(current: Vector2, target: Vector2, delta: float, rate: float, snap_dist: float) -> Vector2:
	if current.distance_to(target) > snap_dist:
		return target
	return current.lerp(target, 1.0 - exp(-rate * delta))


## Distinct, stable colour per NPC id ("npc:3"): golden-ratio hue steps.
static func color_for_id(id: String) -> Color:
	var n := id.get_slice(":", 1).to_int() if id.contains(":") else id.hash()
	return Color.from_hsv(fposmod(n * 0.618034, 1.0), 0.6, 0.85)


## TileDef.placeholder_color of a material key (magenta if unknown).
static func material_color(reg: TileRegistry, material: StringName) -> Color:
	for d in reg.all_defs():
		if d.key == material:
			return d.placeholder_color
	return Color.MAGENTA
