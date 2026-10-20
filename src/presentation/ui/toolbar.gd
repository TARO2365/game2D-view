class_name Toolbar
extends HBoxContainer
## In-game tool buttons. Emits intents only; GameScreen issues the commands.

signal tool_selected(tool: int)
signal zoom_requested(factor: float)
signal save_requested
signal menu_requested

## Touch-friendly minimum size. PLACEHOLDER until UX prototype (spec §9).
const BUTTON_MIN_SIZE := Vector2(56, 44)
const ZOOM_STEP := 1.25
const TOOLS := [
	[ToolController.Tool.SELECT, "Select", "Pan the camera (drag)"],
	[ToolController.Tool.DIG, "Dig", "Order: dig the dragged area"],
	[ToolController.Tool.BUILD, "Build wall", "Order: build walls in the dragged area"],
	[ToolController.Tool.CANCEL, "Cancel", "Remove orders in the dragged area"],
]

var _tool_buttons: Dictionary = {}  # Tool -> Button


func _ready() -> void:
	var group := ButtonGroup.new()
	for entry in TOOLS:
		var b := _make(entry[1], entry[2])
		b.toggle_mode = true
		b.button_group = group
		b.pressed.connect(func() -> void: tool_selected.emit(entry[0]))
		_tool_buttons[entry[0]] = b
	add_child(VSeparator.new())
	_make("−", "Zoom out").pressed.connect(func() -> void: zoom_requested.emit(1.0 / ZOOM_STEP))
	_make("+", "Zoom in").pressed.connect(func() -> void: zoom_requested.emit(ZOOM_STEP))
	add_child(VSeparator.new())
	_make("Save", "Save now (Ctrl+S)").pressed.connect(func() -> void: save_requested.emit())
	_make("Menu", "Save and return to the main menu").pressed.connect(func() -> void: menu_requested.emit())


func set_active_tool(t: int) -> void:
	for k in _tool_buttons:
		_tool_buttons[k].set_pressed_no_signal(k == t)


func get_tool_button(t: int) -> Button:
	return _tool_buttons.get(t)


func _make(text: String, tip: String) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.custom_minimum_size = BUTTON_MIN_SIZE
	add_child(b)
	return b
