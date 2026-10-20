class_name Toolbar
extends VBoxContainer
## In-game tool buttons (two rows). Emits intents only; GameScreen issues the
## commands. Row 1: tools. Row 2: zoom, save, menu and the 1-9 priority
## selector (shown while the Priority tool or an order tool is active).

signal tool_selected(tool: int)
signal priority_selected(priority: int)
signal zoom_requested(factor: float)
signal save_requested
signal menu_requested

## Touch-friendly minimum size. PLACEHOLDER until UX prototype (spec §9).
const BUTTON_MIN_SIZE := Vector2(56, 44)
const PRIORITY_BUTTON_SIZE := Vector2(44, 44)
const ZOOM_STEP := 1.25
const TOOLS := [
	[ToolController.Tool.SELECT, "Select", "Pan the camera (drag); click an NPC to inspect it"],
	[ToolController.Tool.DIG, "Dig", "Order: dig the dragged area"],
	[ToolController.Tool.BUILD, "Build wall", "Order: build walls in the dragged area"],
	[ToolController.Tool.LADDER, "Ladder", "Order: build ladders in the dragged open area"],
	[ToolController.Tool.STOCKPILE, "Stockpile", "Mark the dragged floor area as a stockpile"],
	[ToolController.Tool.CLEAR_STOCKPILE, "Clear stockpile", "Remove stockpile tiles in the dragged area"],
	[ToolController.Tool.PRIORITY, "Priority", "Set the chosen priority on orders in the dragged area"],
	[ToolController.Tool.CANCEL, "Cancel", "Remove orders in the dragged area"],
]

var priority_box: HBoxContainer

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
		var b := _make(_tools_row, entry[1], entry[2])
		b.toggle_mode = true
		b.button_group = group
		b.pressed.connect(func() -> void: tool_selected.emit(entry[0]))
		_tool_buttons[entry[0]] = b
	_make(_misc_row, "−", "Zoom out").pressed.connect(func() -> void: zoom_requested.emit(1.0 / ZOOM_STEP))
	_make(_misc_row, "+", "Zoom in").pressed.connect(func() -> void: zoom_requested.emit(ZOOM_STEP))
	_misc_row.add_child(VSeparator.new())
	_make(_misc_row, "Save", "Save now (Ctrl+S)").pressed.connect(func() -> void: save_requested.emit())
	_make(_misc_row, "Menu", "Save and return to the main menu").pressed.connect(func() -> void: menu_requested.emit())
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


func get_tool_button(t: int) -> Button:
	return _tool_buttons.get(t)


func get_priority_button(p: int) -> Button:
	return _priority_buttons.get(p)


func _make(row: Container, text: String, tip: String) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.custom_minimum_size = BUTTON_MIN_SIZE
	row.add_child(b)
	return b
