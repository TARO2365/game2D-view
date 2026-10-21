class_name Toolbar
extends VBoxContainer
## In-game tool buttons (two rows). Emits intents only; GameScreen issues the
## commands. Row 1: tools (Build opens the build menu). Row 2: zoom, save,
## menu, the Rooms overlay toggle and the 1-9 priority selector (shown while
## the Priority tool or an order tool is active). Buttons show production
## icons ui/icon_<name>.png (ASSET_SPEC §8) when present, text only otherwise.

signal tool_selected(tool: int)
signal build_menu_requested
signal priority_selected(priority: int)
signal rooms_toggled(on: bool)
signal colony_toggled(on: bool)
signal zoom_requested(factor: float)
signal save_requested
signal menu_requested

## Touch-friendly minimum size. PLACEHOLDER until UX prototype (spec §9).
const BUTTON_MIN_SIZE := Vector2(56, 44)
const PRIORITY_BUTTON_SIZE := Vector2(44, 44)
const ICON_MAX_WIDTH := 20  # 24 pushed the toolbar into the HUD column once the owner's icons arrived
const ZOOM_STEP := 1.25
## [tool, label, tooltip, icon name (ASSET_SPEC §8)]
const TOOLS := [
	[ToolController.Tool.SELECT, "Select", "Pan the camera (drag); click an NPC or building to inspect it", &"select"],
	[ToolController.Tool.DIG, "Dig", "Order: dig the dragged area", &"dig"],
	[ToolController.Tool.BUILD, "Build wall", "Order: build walls in the dragged area", &"build"],
	[ToolController.Tool.LADDER, "Ladder", "Order: build ladders in the dragged open area", &"ladder"],
	[ToolController.Tool.PLACE_BUILDING, "Build", "Open the build menu (door, crate, bed, table)", &"build_menu"],
	[ToolController.Tool.DECONSTRUCT, "Deconstruct", "Order: remove walls, ladders and buildings in the dragged area", &"deconstruct"],
	[ToolController.Tool.STOCKPILE, "Stockpile", "Mark the dragged floor area as a stockpile", &"stockpile"],
	[ToolController.Tool.CLEAR_STOCKPILE, "Clear zone", "Remove stockpile tiles in the dragged area", &"clear_stockpile"],
	[ToolController.Tool.PRIORITY, "Priority", "Set the chosen priority on orders in the dragged area", &"priority"],
	[ToolController.Tool.CANCEL, "Cancel", "Remove orders (tiles and buildings) in the dragged area", &"cancel"],
]

var priority_box: HBoxContainer
var rooms_button: Button
var colony_button: Button

var _tool_buttons: Dictionary = {}  # Tool -> Button
var _priority_buttons: Dictionary = {}  # 1..9 -> Button
var _tools_row: HBoxContainer
var _misc_row: HBoxContainer


func _ready() -> void:
	_tools_row = HBoxContainer.new()
	_tools_row.name = "Tools"
	add_child(_tools_row)
	_misc_row = HBoxContainer.new()
	_misc_row.name = "Misc"
	add_child(_misc_row)
	var group := ButtonGroup.new()
	for entry in TOOLS:
		var b := _make(_tools_row, entry[1], entry[2], entry[3])
		b.toggle_mode = true
		b.button_group = group
		if entry[0] == ToolController.Tool.PLACE_BUILDING:
			b.pressed.connect(func() -> void: build_menu_requested.emit())
		else:
			b.pressed.connect(func() -> void: tool_selected.emit(entry[0]))
		_tool_buttons[entry[0]] = b
	_make(_misc_row, "−", "Zoom out").pressed.connect(func() -> void: zoom_requested.emit(1.0 / ZOOM_STEP))
	_make(_misc_row, "+", "Zoom in").pressed.connect(func() -> void: zoom_requested.emit(ZOOM_STEP))
	_misc_row.add_child(VSeparator.new())
	_make(_misc_row, "Save", "Save now (Ctrl+S)").pressed.connect(func() -> void: save_requested.emit())
	_make(_misc_row, "Menu", "Save and return to the main menu").pressed.connect(func() -> void: menu_requested.emit())
	_misc_row.add_child(VSeparator.new())
	rooms_button = _make(_misc_row, "Rooms", "Show rooms by type (R)", &"rooms")
	rooms_button.toggle_mode = true
	rooms_button.toggled.connect(func(on: bool) -> void: rooms_toggled.emit(on))
	colony_button = _make(_misc_row, "Colony", "Colony overview: needs, food, deaths (C)", &"colony")
	colony_button.toggle_mode = true
	colony_button.toggled.connect(func(on: bool) -> void: colony_toggled.emit(on))
	priority_box = HBoxContainer.new()
	priority_box.name = "PrioritySelector"
	_misc_row.add_child(priority_box)
	priority_box.add_child(VSeparator.new())
	var lbl := Label.new()
	lbl.text = "Priority"
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	priority_box.add_child(lbl)
	var pgroup := ButtonGroup.new()
	for p in range(DesignationMap.MIN_PRIORITY, DesignationMap.MAX_PRIORITY + 1):
		var b := _make(priority_box, str(p), "Priority %d (1 lowest, 9 highest)" % p)
		b.custom_minimum_size = PRIORITY_BUTTON_SIZE
		b.toggle_mode = true
		b.button_group = pgroup
		b.pressed.connect(func() -> void: priority_selected.emit(p))
		_priority_buttons[p] = b
	set_active_priority(DesignationMap.DEFAULT_PRIORITY)
	priority_box.visible = false


func set_active_tool(t: int) -> void:
	for k in _tool_buttons:
		_tool_buttons[k].set_pressed_no_signal(k == t)
	priority_box.visible = t == ToolController.Tool.PRIORITY or ToolController.is_order_tool(t)


func set_active_priority(p: int) -> void:
	for k in _priority_buttons:
		_priority_buttons[k].set_pressed_no_signal(k == p)


func set_rooms_active(on: bool) -> void:
	rooms_button.set_pressed_no_signal(on)


func set_colony_active(on: bool) -> void:
	colony_button.set_pressed_no_signal(on)


func get_tool_button(t: int) -> Button:
	return _tool_buttons.get(t)


func get_priority_button(p: int) -> Button:
	return _priority_buttons.get(p)


func _make(row: Container, text: String, tip: String, icon_name: StringName = &"") -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.custom_minimum_size = BUTTON_MIN_SIZE
	if not icon_name.is_empty():
		var tex := ArtLibrary.texture(ArtLibrary.ui_icon_path(icon_name))
		if tex != null:
			b.icon = tex
			b.add_theme_constant_override("icon_max_width", ICON_MAX_WIDTH)
	row.add_child(b)
	return b
