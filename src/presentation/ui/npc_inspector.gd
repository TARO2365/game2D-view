class_name NpcInspector
extends PanelContainer
## Right-side panel for the selected colonist (spec §3): names (Thai), state
## and condition, needs bars, current job, carried item, owned bed, work
## toggles and quick commands. Reads NPC fields every frame while shown;
## emits intents only (GameScreen issues the Colony commands and shows
## failures).

signal work_toggled(work: StringName, on: bool)
signal bed_selected(bed_id: String)
signal move_requested
signal stop_requested
signal schedule_requested
signal close_requested

const PANEL_WIDTH := 300.0        # PLACEHOLDER
const BUTTON_MIN_SIZE := Vector2(0, 44)
const PANEL_COLOR := UiStyle.PANEL_COLOR
const WORK_LABELS := {&"dig": "Dig", &"build": "Build", &"haul": "Haul", &"farm": "Farm", &"cook": "Cook"}
const NEEDS := [[&"hunger", "Hunger", UiStyle.HUNGER_COLOR], [&"stamina", "Stamina", UiStyle.STAMINA_COLOR],
		[&"health", "Health", UiStyle.HEALTH_COLOR]]

var full_name_label: Label
var nickname_label: Label
var state_label: Label
var condition_label: Label
var job_label: Label
var carry_label: Label
var bed_option: OptionButton
var move_button: Button
var stop_button: Button
var schedule_button: Button
var work_checks: Dictionary = {}  # StringName -> CheckBox
var need_bars: Dictionary = {}    # &"hunger"/&"stamina"/&"health" -> ProgressBar

var npc: Npc
var jobs: JobManager
var inventory: Inventory
var registry: TileRegistry
var buildings: Buildings
var colony: Colony
var materials: MaterialDefs

var _bed_ids: Array[String] = []  # option index - 1 -> bed id (index 0 = Auto)


func setup(job_manager: JobManager, inv: Inventory, reg: TileRegistry, blds: Buildings = null,
		col: Colony = null) -> void:
	jobs = job_manager
	inventory = inv
	registry = reg
	buildings = blds
	colony = col


func _ready() -> void:
	custom_minimum_size = Vector2(PANEL_WIDTH, 0)
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_theme_stylebox_override("panel", UiStyle.panel_box())
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
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
	var st := HBoxContainer.new()
	box.add_child(st)
	state_label = _label(st)
	state_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	condition_label = _label(st)
	job_label = _label(box)
	carry_label = _label(box)
	var needs := GridContainer.new()
	needs.columns = 2
	needs.add_theme_constant_override("v_separation", 2)
	box.add_child(needs)
	for n in NEEDS:
		var l := _label(needs)
		l.text = n[1]
		l.custom_minimum_size = Vector2(70, 0)
		var bar := UiStyle.need_bar(n[2])
		needs.add_child(bar)
		need_bars[n[0]] = bar
	var bed_row := HBoxContainer.new()
	box.add_child(bed_row)
	var bl := _label(bed_row)
	bl.text = "Bed"
	bl.custom_minimum_size = Vector2(70, 0)
	bed_option = OptionButton.new()
	bed_option.custom_minimum_size = BUTTON_MIN_SIZE
	bed_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bed_option.tooltip_text = "Owned bed; Auto picks a free one"
	bed_option.item_selected.connect(_on_bed_selected)
	bed_row.add_child(bed_option)
	var works := GridContainer.new()
	works.columns = 3
	box.add_child(works)
	for w: StringName in Npc.WORK_KEYS:
		var cb := CheckBox.new()
		cb.text = WORK_LABELS.get(w, String(w).capitalize())
		cb.custom_minimum_size = BUTTON_MIN_SIZE
		cb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cb.toggled.connect(func(on: bool) -> void: work_toggled.emit(w, on))
		works.add_child(cb)
		work_checks[w] = cb
	var cmds := HBoxContainer.new()
	box.add_child(cmds)
	move_button = _cmd(cmds, "Move here", "Then click a place in the world (Esc / right-click cancels)")
	move_button.toggle_mode = true
	move_button.pressed.connect(func() -> void: move_requested.emit())
	stop_button = _cmd(cmds, "Stop", "Stop the current job")
	stop_button.pressed.connect(func() -> void: stop_requested.emit())
	schedule_button = _cmd(cmds, "Schedule", "Edit the 24-hour work / sleep / free schedule")
	schedule_button.toggle_mode = true
	schedule_button.pressed.connect(func() -> void: schedule_requested.emit())
	visible = npc != null


func show_npc(n: Npc) -> void:
	npc = n
	visible = n != null
	set_move_pending(false)
	refresh()


func set_move_pending(on: bool) -> void:
	if move_button:
		move_button.set_pressed_no_signal(on)
		move_button.text = "Click…" if on else "Move here"


func set_schedule_open(on: bool) -> void:
	if schedule_button:
		schedule_button.set_pressed_no_signal(on)


func _process(_delta: float) -> void:
	if visible:
		refresh()


func refresh() -> void:
	if npc == null or full_name_label == null:
		return
	full_name_label.text = npc.full_name
	nickname_label.text = "Nickname: %s" % npc.nickname
	state_label.text = "Doing: %s" % npc.state
	condition_label.text = UiStyle.condition_name(npc.condition)
	condition_label.add_theme_color_override("font_color",
			Color(0.6, 1.0, 0.6) if npc.condition == Npc.CONDITION_OK else UiStyle.severity_color(2))
	var job: String = jobs.describe_job(npc.job_id) if not npc.job_id.is_empty() else ""
	if job.is_empty() and npc.command_target != Npc.NO_TILE:
		job = "Move to (%d, %d)" % [npc.command_target.x, npc.command_target.y]
	job_label.text = "Job: %s" % (job if not job.is_empty() else "none")
	var it := inventory.carried_by(npc.id)
	carry_label.text = "Carrying: %s" % (carry_text(registry, it, materials) if it != null else "nothing")
	need_bars[&"hunger"].value = npc.hunger
	need_bars[&"stamina"].value = npc.stamina
	need_bars[&"health"].value = npc.health
	for k in need_bars:
		(need_bars[k] as ProgressBar).tooltip_text = "%.0f / 100" % float(npc.get(k))
	_refresh_beds()
	for w in work_checks:
		(work_checks[w] as CheckBox).set_pressed_no_signal(bool(npc.work_enabled.get(w, false)))


## Rebuilds the bed list when the set of beds changes; selects the NPC's bed.
func _refresh_beds() -> void:
	var ids: Array[String] = []
	if buildings != null:
		for id in buildings.all_ids():
			if buildings.get_building(id).get("key", &"") == &"bed":
				ids.append(id)
	if ids != _bed_ids or bed_option.item_count != ids.size() + 1:
		_bed_ids = ids
		bed_option.clear()
		bed_option.add_item("Auto")
		for id in ids:
			var o: Vector2i = buildings.get_building(id)["origin"]
			bed_option.add_item("Bed at (%d, %d)" % [o.x, o.y])
	for i in _bed_ids.size():
		bed_option.set_item_text(i + 1, bed_label(_bed_ids[i]))
	var sel := _bed_ids.find(npc.bed_id) + 1
	if bed_option.selected != sel:
		bed_option.select(sel)


## "Bed at (x, y)" plus the owner's nickname when someone else owns it.
func bed_label(bed_id: String) -> String:
	var o: Vector2i = buildings.get_building(bed_id)["origin"]
	var text := "Bed at (%d, %d)" % [o.x, o.y]
	if colony != null:
		for n in colony.all_npcs():
			if n.bed_id == bed_id and n != npc:
				text += " – %s" % n.nickname
	return text


## Bed id of an option index (0 = Auto = "").
func bed_id_at(index: int) -> String:
	return _bed_ids[index - 1] if index >= 1 and index <= _bed_ids.size() else ""


func _on_bed_selected(index: int) -> void:
	bed_selected.emit(bed_id_at(index))


static func carry_text(reg: TileRegistry, it: ItemStack, mats: MaterialDefs = null) -> String:
	var mat_name := String(it.material)
	if mats != null and mats.has(it.material):
		mat_name = mats.get_def(it.material).display_name
	else:
		for d in reg.all_defs():
			if d.key == it.material:
				mat_name = d.display_name
	return "%s %.0f kg" % [mat_name, it.kg]


func _label(parent: Control) -> Label:
	var l := Label.new()
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(l)
	return l


func _cmd(parent: Control, text: String, tip: String) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.custom_minimum_size = BUTTON_MIN_SIZE
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(b)
	return b
