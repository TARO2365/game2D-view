class_name NpcInspector
extends PanelContainer
## Right-side panel for the selected colonist (spec §3): names (Thai), state,
## current job, carried item, work toggles and quick commands. Reads NPC
## fields every frame while shown; emits intents only (GameScreen issues the
## Colony commands and shows failures).

signal work_toggled(work: StringName, on: bool)
signal move_requested
signal stop_requested
signal close_requested

const PANEL_WIDTH := 300.0        # PLACEHOLDER
const BUTTON_MIN_SIZE := Vector2(0, 44)
const PANEL_COLOR := Color(0.11, 0.1, 0.12, 0.96)  # PLACEHOLDER
const PANEL_BORDER := Color(0.45, 0.4, 0.3)
const WORK_LABELS := {&"dig": "Dig", &"build": "Build", &"haul": "Haul"}

var full_name_label: Label
var nickname_label: Label
var state_label: Label
var job_label: Label
var carry_label: Label
var move_button: Button
var stop_button: Button
var work_checks: Dictionary = {}  # StringName -> CheckBox

var npc: Npc
var jobs: JobManager
var inventory: Inventory
var registry: TileRegistry


func setup(job_manager: JobManager, inv: Inventory, reg: TileRegistry) -> void:
	jobs = job_manager
	inventory = inv
	registry = reg


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
	full_name_label = Label.new()
	full_name_label.add_theme_font_size_override("font_size", 20)
	full_name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	full_name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	head.add_child(full_name_label)
	var close := Button.new()
	close.text = "×"
	close.tooltip_text = "Deselect (Esc)"
	close.custom_minimum_size = Vector2(44, 44)
	close.pressed.connect(func() -> void: close_requested.emit())
	head.add_child(close)
	nickname_label = _label(box)
	state_label = _label(box)
	job_label = _label(box)
	carry_label = _label(box)
	box.add_child(HSeparator.new())
	var work_hdr := _label(box)
	work_hdr.text = "Allowed work"
	var works := HBoxContainer.new()
	box.add_child(works)
	for w: StringName in Npc.WORK_KEYS:
		var cb := CheckBox.new()
		cb.text = WORK_LABELS.get(w, String(w))
		cb.custom_minimum_size = BUTTON_MIN_SIZE
		cb.toggled.connect(func(on: bool) -> void: work_toggled.emit(w, on))
		works.add_child(cb)
		work_checks[w] = cb
	box.add_child(HSeparator.new())
	var cmds := HBoxContainer.new()
	box.add_child(cmds)
	move_button = Button.new()
	move_button.text = "Move here"
	move_button.tooltip_text = "Then click a place in the world (Esc / right-click cancels)"
	move_button.toggle_mode = true
	move_button.custom_minimum_size = BUTTON_MIN_SIZE
	move_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	move_button.pressed.connect(func() -> void: move_requested.emit())
	cmds.add_child(move_button)
	stop_button = Button.new()
	stop_button.text = "Stop"
	stop_button.tooltip_text = "Stop the current job"
	stop_button.custom_minimum_size = BUTTON_MIN_SIZE
	stop_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stop_button.pressed.connect(func() -> void: stop_requested.emit())
	cmds.add_child(stop_button)
	visible = npc != null


func show_npc(n: Npc) -> void:
	npc = n
	visible = n != null
	set_move_pending(false)
	refresh()


func set_move_pending(on: bool) -> void:
	if move_button:
		move_button.set_pressed_no_signal(on)
		move_button.text = "Click a place…" if on else "Move here"


func _process(_delta: float) -> void:
	if visible:
		refresh()


func refresh() -> void:
	if npc == null or full_name_label == null:
		return
	full_name_label.text = npc.full_name
	nickname_label.text = "Nickname: %s" % npc.nickname
	state_label.text = "State: %s" % npc.state
	var job: String = jobs.describe_job(npc.job_id) if not npc.job_id.is_empty() else ""
	if job.is_empty() and npc.command_target != Npc.NO_TILE:
		job = "Move to (%d, %d)" % [npc.command_target.x, npc.command_target.y]
	job_label.text = "Job: %s" % (job if not job.is_empty() else "none")
	var it := inventory.carried_by(npc.id)
	carry_label.text = "Carrying: %s" % (carry_text(registry, it) if it != null else "nothing")
	for w in work_checks:
		(work_checks[w] as CheckBox).set_pressed_no_signal(bool(npc.work_enabled.get(w, false)))


static func carry_text(reg: TileRegistry, it: ItemStack) -> String:
	var mat_name := String(it.material)
	for d in reg.all_defs():
		if d.key == it.material:
			mat_name = d.display_name
	return "%s %.0f kg" % [mat_name, it.kg]


func _label(parent: Control) -> Label:
	var l := Label.new()
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(l)
	return l
