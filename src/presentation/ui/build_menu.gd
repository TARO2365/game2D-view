class_name BuildMenu
extends PanelContainer
## Small panel listing every BuildingDef (name, size, materials + kg, icon).
## Choosing one emits building_chosen; GameScreen enters placement mode.

signal building_chosen(key: StringName)
signal close_requested

const ICON_SIZE := Vector2(44, 44)
const ENTRY_MIN_HEIGHT := 52.0
const PANEL_COLOR := Color(0.11, 0.1, 0.12, 0.96)  # PLACEHOLDER
const PANEL_BORDER := Color(0.45, 0.4, 0.3)

var defs: Array[BuildingDef] = []
var tile_registry: TileRegistry
## key -> Button (tests).
var entry_buttons: Dictionary = {}


func setup(building_defs: Array[BuildingDef], reg: TileRegistry) -> void:
	defs = building_defs
	tile_registry = reg


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	var bg := StyleBoxFlat.new()
	bg.bg_color = PANEL_COLOR
	bg.border_color = PANEL_BORDER
	bg.set_border_width_all(2)
	bg.set_corner_radius_all(4)
	bg.set_content_margin_all(8)
	add_theme_stylebox_override("panel", bg)
	var box := VBoxContainer.new()
	add_child(box)
	var head := HBoxContainer.new()
	box.add_child(head)
	var title := Label.new()
	title.text = "Build"
	title.add_theme_font_size_override("font_size", 20)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var close := Button.new()
	close.text = "×"
	close.tooltip_text = "Close (Esc)"
	close.custom_minimum_size = Vector2(44, 44)
	close.pressed.connect(func() -> void: close_requested.emit())
	head.add_child(close)
	for d in defs:
		var row := HBoxContainer.new()
		box.add_child(row)
		var icon := BuildingIcon.new()
		icon.key = d.key
		icon.tiles = Vector2(d.size)
		icon.custom_minimum_size = ICON_SIZE
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(icon)
		var b := Button.new()
		b.text = entry_text(d, tile_registry)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(250, ENTRY_MIN_HEIGHT)
		b.tooltip_text = "Then click where its bottom-left tile goes (Esc / right-click to stop)"
		var key := d.key
		b.pressed.connect(func() -> void: building_chosen.emit(key))
		row.add_child(b)
		entry_buttons[d.key] = b


## "Bed  2×1\nrock or dirt · 50 kg"
static func entry_text(d: BuildingDef, reg: TileRegistry) -> String:
	var mats: Array[String] = []
	for m in d.materials:
		mats.append(material_name(reg, m))
	var extra := ""
	if d.storage_kg > 0.0:
		extra = " · holds %.0f kg" % d.storage_kg
	return "%s  %d×%d\n%s · %.0f kg%s" % [d.display_name, d.size.x, d.size.y, " or ".join(mats), d.kg, extra]


static func material_name(reg: TileRegistry, material: StringName) -> String:
	if reg != null:
		for t in reg.all_defs():
			if t.key == material:
				return t.display_name
	return String(material).capitalize()


## Building icon: the same art/shape as in the world, fitted into the control.
class BuildingIcon extends Control:
	var key: StringName
	var tiles := Vector2.ONE  # footprint size, keeps the aspect ratio

	func _draw() -> void:
		var area := Rect2(Vector2.ZERO, size).grow(-4.0)
		var s := minf(area.size.x / tiles.x, area.size.y / tiles.y)
		var fit := tiles * s
		BuildingView.draw_art(self, key, Rect2(area.position + (area.size - fit) / 2.0, fit))
