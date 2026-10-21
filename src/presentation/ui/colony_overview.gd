class_name ColonyOverview
extends PanelContainer
## Every colonist with needs bars and state, plus food in stock (kg per food
## material) and deaths. Clicking a row emits npc_clicked (GameScreen selects
## and centres that NPC). Read-only.

signal npc_clicked(npc_id: String)
signal close_requested

const PANEL_WIDTH := 600.0        # PLACEHOLDER
const LIST_HEIGHT := 250.0
const BAR_WIDTH := 70.0

var colony: Colony
var inventory: Inventory
var materials: MaterialDefs
var food_label: Label
var deaths_label: Label
var list: VBoxContainer
## npc id -> {"button": Button, "hunger"/"stamina"/"health": ProgressBar}
var rows: Dictionary = {}

var _ids: Array[String] = []


func setup(c: Colony, inv: Inventory, mats: MaterialDefs) -> void:
	colony = c
	inventory = inv
	materials = mats


func _ready() -> void:
	custom_minimum_size = Vector2(PANEL_WIDTH, 0)
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_theme_stylebox_override("panel", UiStyle.panel_box())
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	add_child(box)
	var head := HBoxContainer.new()
	box.add_child(head)
	var title := Label.new()
	title.text = "Colony"
	title.add_theme_font_size_override("font_size", 20)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	deaths_label = Label.new()
	head.add_child(deaths_label)
	var close := Button.new()
	close.text = "×"
	close.tooltip_text = "Close (C)"
	close.custom_minimum_size = Vector2(44, 44)
	close.pressed.connect(func() -> void: close_requested.emit())
	head.add_child(close)
	food_label = Label.new()
	food_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(food_label)
	var cols := HBoxContainer.new()
	box.add_child(cols)
	for t in ["Colonist", "Hunger", "Stamina", "Health"]:
		var l := Label.new()
		l.text = t
		l.add_theme_font_size_override("font_size", 13)
		l.custom_minimum_size = Vector2(BAR_WIDTH if t != "Colonist" else 0, 0)
		if t == "Colonist":
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cols.add_child(l)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, LIST_HEIGHT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	list = VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	refresh()


func _process(_delta: float) -> void:
	if visible:
		refresh()


func refresh() -> void:
	if list == null:
		return
	var ids: Array[String] = []
	for n in colony.all_npcs():
		ids.append(n.id)
	if ids != _ids:
		_rebuild(ids)
	for n in colony.all_npcs():
		var r: Dictionary = rows[n.id]
		(r["button"] as Button).text = "%s  ·  %s%s" % [n.nickname, n.state,
				"" if n.condition == Npc.CONDITION_OK else "  (%s)" % UiStyle.condition_name(n.condition)]
		(r["hunger"] as ProgressBar).value = n.hunger
		(r["stamina"] as ProgressBar).value = n.stamina
		(r["health"] as ProgressBar).value = n.health
	food_label.text = "Food in stock: " + food_text()
	deaths_label.text = "Deaths: %d  " % colony.deaths()


## "Ration 20 kg · Meal 0 kg · Cave Mushroom 0 kg" (all items that exist,
## including carried ones).
func food_text() -> String:
	var totals := inventory.total_kg_by_material()
	var parts: Array[String] = []
	for f in materials.foods():
		parts.append("%s %.0f kg" % [materials.get_def(f).display_name, float(totals.get(f, 0.0))])
	return " · ".join(parts)


func _rebuild(ids: Array[String]) -> void:
	_ids = ids
	for c in list.get_children():
		list.remove_child(c)
		c.queue_free()
	rows.clear()
	for id in ids:
		var row := HBoxContainer.new()
		list.add_child(row)
		var b := Button.new()
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(0, 44)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.clip_text = true
		b.tooltip_text = "Select and centre the camera"
		var npc_id := id
		b.pressed.connect(func() -> void: npc_clicked.emit(npc_id))
		row.add_child(b)
		var entry := {"button": b}
		for k in [[&"hunger", UiStyle.HUNGER_COLOR], [&"stamina", UiStyle.STAMINA_COLOR],
				[&"health", UiStyle.HEALTH_COLOR]]:
			var bar := UiStyle.need_bar(k[1])
			bar.custom_minimum_size = Vector2(BAR_WIDTH, 12)
			bar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			row.add_child(bar)
			entry[k[0]] = bar
		rows[id] = entry
