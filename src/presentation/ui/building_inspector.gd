class_name BuildingInspector
extends PanelContainer
## Right-side panel for a selected building: name, size, contents (crates:
## kg per material) and, for crates, a material filter. Emits intents only;
## GameScreen calls CrateStorage.set_filter / DesignationMap.designate.

signal filter_changed(materials: Array[StringName])
signal deconstruct_requested
signal close_requested

const PANEL_WIDTH := 300.0        # PLACEHOLDER
const BUTTON_MIN_SIZE := Vector2(0, 44)
const PANEL_COLOR := Color(0.11, 0.1, 0.12, 0.96)  # PLACEHOLDER
const PANEL_BORDER := Color(0.45, 0.4, 0.3)

var title_label: Label
var info_label: Label
var contents_label: Label
var filter_box: VBoxContainer
var deconstruct_button: Button
## material key -> CheckBox
var filter_checks: Dictionary = {}

var building_id := ""
var buildings: Buildings
var crates: CrateStorage
var inventory: Inventory
var tile_registry: TileRegistry
## Materials offered in the filter: tile defs that drop an item (drop_kg > 0).
var filter_materials: Array[StringName] = []


func setup(b: Buildings, c: CrateStorage, inv: Inventory, reg: TileRegistry) -> void:
	buildings = b
	crates = c
	inventory = inv
	tile_registry = reg
	for d in reg.all_defs():
		if d.drop_kg > 0.0:
			filter_materials.append(d.key)


func _ready() -> void:
	custom_minimum_size = Vector2(PANEL_WIDTH, 0)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var bg := StyleBoxFlat.new()
	bg.bg_color = PANEL_COLOR
	bg.border_color = PANEL_BORDER
	bg.set_border_width_all(2)
	bg.set_corner_radius_all(4)
	bg.set_content_margin_all(10)
	add_theme_stylebox_override("panel", bg)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	add_child(box)
	var head := HBoxContainer.new()
	box.add_child(head)
	title_label = Label.new()
	title_label.add_theme_font_size_override("font_size", 20)
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title_label)
	var close := Button.new()
	close.text = "×"
	close.tooltip_text = "Deselect (Esc)"
	close.custom_minimum_size = Vector2(44, 44)
	close.pressed.connect(func() -> void: close_requested.emit())
	head.add_child(close)
	info_label = _label(box)
	contents_label = _label(box)
	filter_box = VBoxContainer.new()
	box.add_child(filter_box)
	filter_box.add_child(HSeparator.new())
	var hdr := _label(filter_box)
	hdr.text = "Accepts"
	var grid := GridContainer.new()
	grid.columns = 2
	filter_box.add_child(grid)
	for m in filter_materials:
		var cb := CheckBox.new()
		cb.text = BuildMenu.material_name(tile_registry, m)
		cb.custom_minimum_size = BUTTON_MIN_SIZE
		cb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cb.toggled.connect(func(_on: bool) -> void: filter_changed.emit(checked_materials()))
		grid.add_child(cb)
		filter_checks[m] = cb
	box.add_child(HSeparator.new())
	deconstruct_button = Button.new()
	deconstruct_button.text = "Deconstruct"
	deconstruct_button.tooltip_text = "Order NPCs to take it apart (materials are returned)"
	deconstruct_button.custom_minimum_size = BUTTON_MIN_SIZE
	deconstruct_button.pressed.connect(func() -> void: deconstruct_requested.emit())
	box.add_child(deconstruct_button)
	visible = not building_id.is_empty()


func show_building(id: String) -> void:
	building_id = id
	visible = not id.is_empty()
	refresh()


func is_crate() -> bool:
	return not building_id.is_empty() and crates.is_crate(building_id)


## Checked filter materials. All checked = [] (accept everything).
func checked_materials() -> Array[StringName]:
	var out: Array[StringName] = []
	for m in filter_checks:
		if (filter_checks[m] as CheckBox).button_pressed:
			out.append(m)
	if out.size() == filter_checks.size():
		out.clear()
	return out


func _process(_delta: float) -> void:
	if visible:
		refresh()


func refresh() -> void:
	if building_id.is_empty() or title_label == null:
		return
	var b := buildings.get_building(building_id)
	if b.is_empty():
		show_building("")
		return
	var d := buildings.def(b["key"])
	title_label.text = d.display_name if d else String(b["key"])
	info_label.text = "Size %d×%d at (%d, %d)" % [d.size.x, d.size.y, b["origin"].x, b["origin"].y] if d else ""
	var crate := is_crate()
	filter_box.visible = crate
	if crate:
		contents_label.text = contents_text()
		var filter := crates.get_filter(building_id)
		for m in filter_checks:
			(filter_checks[m] as CheckBox).set_pressed_no_signal(filter.is_empty() or filter.has(m))
	else:
		contents_label.text = ""
	contents_label.visible = crate


## "Stored 150 / 2000 kg\n  Dirt 100 kg\n  Rock 50 kg"
func contents_text() -> String:
	var d := buildings.def(buildings.get_building(building_id).get("key", &""))
	var per: Dictionary = {}
	for it in inventory.crate_items(building_id):
		per[it.material] = float(per.get(it.material, 0.0)) + it.kg
	var lines: Array[String] = ["Stored %.0f / %.0f kg" % [inventory.crate_kg(building_id), d.storage_kg if d else 0.0]]
	var keys := per.keys()
	keys.sort()
	for m in keys:
		lines.append("  %s %.0f kg" % [BuildMenu.material_name(tile_registry, m), per[m]])
	if per.is_empty():
		lines.append("  (empty)")
	return "\n".join(lines)


func _label(parent: Control) -> Label:
	var l := Label.new()
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(l)
	return l
