class_name ScheduleEditor
extends PanelContainer
## 24 hour cells (two rows of 12) for one NPC; a click cycles
## Work -> Sleep -> Free. Emits intents only: GameScreen calls
## Colony.set_schedule / set_schedule_all.

signal schedule_changed(hours: PackedByteArray)
signal apply_all_requested(hours: PackedByteArray)
signal close_requested

const CELL_SIZE := Vector2(44, 44)   # touch target. PLACEHOLDER
const ACTIVITY_COLORS := {
	Npc.Activity.WORK: Color(0.85, 0.55, 0.2),
	Npc.Activity.SLEEP: Color(0.25, 0.3, 0.6),
	Npc.Activity.FREE: Color(0.3, 0.6, 0.35),
}
const ACTIVITY_LETTERS := {Npc.Activity.WORK: "W", Npc.Activity.SLEEP: "S", Npc.Activity.FREE: "F"}
const CYCLE := [Npc.Activity.WORK, Npc.Activity.SLEEP, Npc.Activity.FREE]

var title_label: Label
var hours: PackedByteArray = Npc.default_schedule()
## 0..23 -> Button
var cells: Array[Button] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_theme_stylebox_override("panel", UiStyle.panel_box())
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	add_child(box)
	var head := HBoxContainer.new()
	box.add_child(head)
	title_label = Label.new()
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title_label)
	var legend := Label.new()
	legend.text = "W work · S sleep · F free"
	legend.add_theme_font_size_override("font_size", 13)
	head.add_child(legend)
	var close := Button.new()
	close.text = "×"
	close.custom_minimum_size = Vector2(44, 44)
	close.pressed.connect(func() -> void: close_requested.emit())
	head.add_child(close)
	for row in 2:
		var labels := HBoxContainer.new()
		labels.add_theme_constant_override("separation", 2)
		box.add_child(labels)
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 2)
		box.add_child(line)
		for i in 12:
			var h := row * 12 + i
			var hl := Label.new()
			hl.text = "%02d" % h
			hl.custom_minimum_size = Vector2(CELL_SIZE.x, 0)
			hl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			hl.add_theme_font_size_override("font_size", 12)
			labels.add_child(hl)
			var b := Button.new()
			b.custom_minimum_size = CELL_SIZE
			b.tooltip_text = "%02d:00–%02d:00" % [h, (h + 1) % 24]
			b.pressed.connect(func() -> void: cycle_hour(h))
			line.add_child(b)
			cells.append(b)
	var foot := HBoxContainer.new()
	box.add_child(foot)
	var all := Button.new()
	all.text = "Apply to all colonists"
	all.custom_minimum_size = Vector2(0, 44)
	all.pressed.connect(func() -> void: apply_all_requested.emit(hours.duplicate()))
	foot.add_child(all)
	_paint()


func show_schedule(who: String, h: PackedByteArray) -> void:
	hours = h.duplicate()
	if title_label:
		title_label.text = "Schedule: %s" % who
	_paint()


## Work -> Sleep -> Free -> Work for one hour; emits the new schedule.
func cycle_hour(h: int) -> void:
	hours[h] = next_activity(hours[h])
	_paint()
	schedule_changed.emit(hours.duplicate())


static func next_activity(a: int) -> int:
	var i := CYCLE.find(a)
	return CYCLE[(i + 1) % CYCLE.size()]


func _paint() -> void:
	for h in cells.size():
		var a: int = hours[h] if h < hours.size() else Npc.Activity.WORK
		var b := cells[h]
		b.text = ACTIVITY_LETTERS.get(a, "?")
		var sb := StyleBoxFlat.new()
		sb.bg_color = ACTIVITY_COLORS.get(a, Color.GRAY)
		sb.set_corner_radius_all(3)
		for st in ["normal", "hover", "pressed", "focus"]:
			b.add_theme_stylebox_override(st, sb)
