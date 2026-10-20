class_name MainMenu
extends Control
## World list (max 3, D-014), New World dialog with name field (D-016) and
## delete confirmation. Issues WorldSlots commands and shows their results.

signal play_requested(session: WorldSession, notice: String)

const BUTTON_MIN_SIZE := Vector2(110, 44)

var slots: WorldSlots
var status_label: Label
var new_world_button: Button
var name_edit: LineEdit
var seed_edit: LineEdit
var size_option: OptionButton
var new_world_overlay: Control
var delete_dialog: ConfirmationDialog

var _list: VBoxContainer
var _pending_delete := ""


func setup(world_slots: WorldSlots) -> void:
	slots = world_slots


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.06, 0.06)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(560, 0)
	box.add_theme_constant_override("separation", 12)
	center.add_child(box)

	var title := Label.new()
	title.text = "PROJECT LAST BUNKER"
	title.add_theme_font_size_override("font_size", 40)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	var sub := Label.new()
	sub.text = "M3 build — placeholder art"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(sub)
	var hdr := Label.new()
	hdr.text = "Worlds (up to %d stored, one played at a time)" % WorldSlots.MAX_WORLDS
	box.add_child(hdr)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 8)
	box.add_child(_list)
	new_world_button = _button("New World", open_new_world_dialog)
	box.add_child(new_world_button)
	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(status_label)

	_build_new_world_overlay()
	delete_dialog = ConfirmationDialog.new()
	delete_dialog.ok_button_text = "Delete"
	delete_dialog.confirmed.connect(confirm_delete)
	add_child(delete_dialog)
	refresh()


func refresh() -> void:
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	var worlds := slots.list_worlds()
	if worlds.is_empty():
		var empty := Label.new()
		empty.text = "No worlds yet."
		_list.add_child(empty)
	for m in worlds:
		var row := HBoxContainer.new()
		var info := Label.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info.text = "%s\n%s · seed %d · last played %s" % [m["name"], String(m.get("preset", "")).capitalize(),
				m["seed"], _format_time(float(m["last_played_unix"]))]
		row.add_child(info)
		row.add_child(_button("Play", play_world.bind(m["id"])))
		row.add_child(_button("Delete", request_delete.bind(m["id"])))
		_list.add_child(row)
	var can := slots.can_create()
	new_world_button.disabled = not can
	new_world_button.tooltip_text = "" if can else "Delete a world first"
	if not can:
		status_label.text = "World limit reached (%d). Delete a world to create a new one." % WorldSlots.MAX_WORLDS


func open_new_world_dialog() -> void:
	if not slots.can_create():
		refresh()
		return
	name_edit.text = slots.suggest_name()
	reroll_seed()
	size_option.select(1)
	new_world_overlay.visible = true
	name_edit.grab_focus()


## D-018: seeds are random by default; the player may still type one.
func reroll_seed() -> void:
	seed_edit.text = str(WorldGenerator.seed_from_text(""))


func close_new_world_dialog() -> void:
	new_world_overlay.visible = false


func submit_new_world() -> CommandResult:
	var preset: StringName = size_option.get_item_metadata(size_option.selected)
	var r := slots.create_world(name_edit.text, WorldGenerator.seed_from_text(seed_edit.text), preset)
	if r.ok:
		close_new_world_dialog()
		play_requested.emit(r.data["session"], "")
	else:
		status_label.text = r.message
	return r


func play_world(id: String) -> CommandResult:
	var r := slots.load_world(id)
	if r.ok:
		var notice := ""
		if r.data.get("fell_back", false):
			notice = "Loaded %s because a newer save was damaged." % r.data["source"]
		play_requested.emit(r.data["session"], notice)
	else:
		status_label.text = "Could not load world: %s" % r.message
	return r


func request_delete(id: String) -> void:
	_pending_delete = id
	var m := slots.read_meta(id)
	delete_dialog.dialog_text = "Delete world \"%s\"?\nThis cannot be undone." % m.get("name", id)
	delete_dialog.popup_centered()


func confirm_delete() -> CommandResult:
	var r := slots.delete_world(_pending_delete)
	_pending_delete = ""
	status_label.text = "World deleted." if r.ok else r.message
	refresh()
	return r


func _build_new_world_overlay() -> void:
	new_world_overlay = Control.new()
	new_world_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	new_world_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	new_world_overlay.visible = false
	add_child(new_world_overlay)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.7)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	new_world_overlay.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	new_world_overlay.add_child(center)
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.13, 0.12, 0.11)
	style.border_color = Color(0.45, 0.4, 0.3)
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(20)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(420, 0)
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)
	var title := Label.new()
	title.text = "New World"
	title.add_theme_font_size_override("font_size", 24)
	box.add_child(title)
	name_edit = LineEdit.new()
	name_edit.placeholder_text = "World name"
	name_edit.max_length = WorldSlots.NAME_MAX_LEN
	name_edit.custom_minimum_size.y = 44
	box.add_child(_labeled("Name", name_edit))
	seed_edit = LineEdit.new()
	seed_edit.placeholder_text = "Blank = random"
	seed_edit.custom_minimum_size.y = 44
	var seed_row := _labeled("Seed", seed_edit)
	seed_row.add_child(_button("Random", reroll_seed))
	box.add_child(seed_row)
	size_option = OptionButton.new()
	size_option.custom_minimum_size.y = 44
	for key in WorldGenerator.PRESETS:
		var s: Vector2i = WorldGenerator.PRESETS[key]
		size_option.add_item("%s (%d×%d)" % [String(key).capitalize(), s.x, s.y])
		size_option.set_item_metadata(size_option.item_count - 1, key)
	box.add_child(_labeled("Size", size_option))
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_child(_button("Cancel", close_new_world_dialog))
	buttons.add_child(_button("Create", func() -> void: submit_new_world()))
	box.add_child(buttons)


func _labeled(text: String, control: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = text
	l.custom_minimum_size.x = 60
	row.add_child(l)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	return row


func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = BUTTON_MIN_SIZE
	b.pressed.connect(cb)
	return b


static func _format_time(unix: float) -> String:
	var bias_min: int = Time.get_time_zone_from_system().get("bias", 0)
	return Time.get_datetime_string_from_unix_time(int(unix) + bias_min * 60, true)
