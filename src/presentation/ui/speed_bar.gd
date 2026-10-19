class_name SpeedBar
extends HBoxContainer
## Pause / 1x / 2x / 3x control. Issues validated commands to SimulationClock
## and only reflects clock state; it holds no gameplay logic (spec §9).

## Touch-friendly minimum size. PLACEHOLDER until UX prototype (spec §9).
const BUTTON_MIN_SIZE := Vector2(56, 44)
const LABELS := {0: "II", 1: "1x", 2: "2x", 3: "3x"}

var _clock: SimulationClock
var _buttons: Dictionary = {}  # speed -> Button
var _status: Label


func _ready() -> void:
	var group := ButtonGroup.new()
	for s in SimulationClock.ALLOWED_SPEEDS:
		var b := Button.new()
		b.name = "Speed%d" % s
		b.text = LABELS[s]
		b.toggle_mode = true
		b.button_group = group
		b.custom_minimum_size = BUTTON_MIN_SIZE
		b.tooltip_text = "Pause" if s == 0 else "Speed %dx" % s
		b.pressed.connect(_on_speed_pressed.bind(s))
		add_child(b)
		_buttons[s] = b
	_status = Label.new()
	_status.name = "Status"
	_status.custom_minimum_size = Vector2(160, 0)
	_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(_status)
	if _clock:
		_refresh()


func bind_clock(clock: SimulationClock) -> void:
	_clock = clock
	_clock.speed_changed.connect(func(_s: int) -> void: _refresh())
	if is_node_ready():
		_refresh()


func get_button(speed: int) -> Button:
	return _buttons.get(speed)


func _process(_delta: float) -> void:
	if _clock and _status:
		_status.text = "Tick %d  |  %s" % [_clock.tick_index,
				"Paused" if _clock.is_paused() else "%dx" % _clock.speed]


func _on_speed_pressed(s: int) -> void:
	if _clock == null:
		return
	var result := _clock.set_speed(s)
	if not result.ok:
		push_warning(str(result))
	_refresh()


func _refresh() -> void:
	for s in _buttons:
		_buttons[s].set_pressed_no_signal(s == _clock.speed)
