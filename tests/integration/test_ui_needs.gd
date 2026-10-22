extends GutTest
## M4a UI: clock, alerts panel, needs bars, bed picker, schedule editor,
## colony overview, farm/kitchen panels, build menu food buildings, layout.
## Real GameScreen on a real (temp) world; the clock is paused.

const FS := preload("res://tests/helpers/fs_util.gd")
const GAME := preload("res://scenes/game.tscn")

var root: String
var slots: WorldSlots
var session: WorldSession
var game: GameScreen


func before_each() -> void:
	root = FS.temp_root("ui_needs")
	slots = WorldSlots.new(TileRegistry.load_default(), root)
	session = slots.create_world("UI Needs", 5, &"small").data["session"]
	session.clock.set_speed(0)
	game = GAME.instantiate()
	game.setup(session, slots, load("res://data/config/scale_config.tres"))
	add_child_autofree(game)
	await wait_process_frames(2)


func after_each() -> void:
	FS.rm_rf(root)


func _npc() -> Npc:
	return session.colony.all_npcs()[0]


## Surface floor spot near the centre where `key` fits, no NPC on it.
func _spot(key: StringName) -> Vector2i:
	var mid := session.grid.width / 2
	for off in range(4, 80):
		for x in [mid + off, mid - off]:
			var t := Vector2i(x, session.grid.surface_y[x] - 1)
			if session.buildings.can_place(key, t).ok and session.colony.npc_at(t) == null \
					and session.colony.npc_at(t + Vector2i.RIGHT) == null:
				return t
	fail_test("no spot for %s" % key)
	return Vector2i.ZERO


func _key(code: Key) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.pressed = true
	game._unhandled_key_input(e)


func test_clock_shows_day_time_and_sun_moon() -> void:
	game.clock_view.refresh()
	assert_eq(game.clock_view.label.text, GameTime.label(session.clock.tick_index))
	assert_string_contains(game.clock_view.label.text, "Day 1")
	assert_false(game.clock_view.is_night(), "worlds start at 06:00")
	session.clock.tick_index = (21 - GameTime.START_HOUR) * GameTime.TICKS_PER_HOUR
	game.clock_view.refresh()
	assert_string_contains(game.clock_view.label.text, "21:00")
	assert_true(game.clock_view.is_night())
	assert_true(game.clock_view.icon.night, "moon glyph")
	assert_eq(game.clock_view.icon.tooltip_text, "Night")


func test_alerts_grouped_badged_and_pulsing() -> void:
	session.alerts.clear_prefix("")
	var n := _npc()
	session.alerts.set_alert("test/general", AlertService.Severity.GENERAL, "Idle colonists")
	session.alerts.set_alert("test/important", AlertService.Severity.IMPORTANT, "Low food")
	session.alerts.set_alert("test/emergency", AlertService.Severity.EMERGENCY, "%s collapsed" % n.nickname,
			n.tile, n.id)
	await wait_process_frames(1)
	var p := game.alerts_panel
	assert_eq(p.rows.size(), 3)
	assert_eq(p.badge.text, "3")
	assert_eq(p.pulsing_key, "test/emergency", "newest emergency pulses")
	var order: Array[String] = []
	for c in p.list.get_children():
		if c is Label:
			order.append((c as Label).text)
	assert_eq(order, ["Emergency", "Important", "General"] as Array[String])
	var em: Button = p.rows["test/emergency"]
	assert_eq(em.get_theme_color("font_color"), UiStyle.severity_color(2), "red")
	assert_eq((p.rows["test/important"] as Button).get_theme_color("font_color"), UiStyle.severity_color(1), "orange")
	session.alerts.clear("test/general")
	await wait_process_frames(1)
	assert_eq(p.badge.text, "2")


func test_clicking_alert_selects_and_centres_npc() -> void:
	var n := session.colony.all_npcs()[1]
	game.camera.position = Vector2(500, 500)
	session.alerts.set_alert("test/npc", AlertService.Severity.EMERGENCY, "help", n.tile, n.id)
	await wait_process_frames(1)
	(game.alerts_panel.rows["test/npc"] as Button).pressed.emit()
	assert_eq(game.selected_npc_id, n.id)
	assert_true(game.inspector.visible)
	var px := game.scale_config.tile_size_px
	assert_lt(game.camera.position.distance_to(Vector2(n.tile) * px), 4.0 * px, "camera on the NPC")


func test_clicking_tile_alert_centres_camera() -> void:
	var t := Vector2i(session.grid.width / 2 + 20, session.grid.surface_y[session.grid.width / 2] + 10)
	session.alerts.set_alert("test/tile", AlertService.Severity.IMPORTANT, "blocked", t)
	await wait_process_frames(1)
	(game.alerts_panel.rows["test/tile"] as Button).pressed.emit()
	var px := game.scale_config.tile_size_px
	assert_lt(game.camera.position.distance_to((Vector2(t) + Vector2(0.5, 0.5)) * px), 1.0)
	assert_false(game.focus_alert({"key": "x", "tile": AlertService.NO_TILE, "npc_id": ""}).ok)


func test_inspector_needs_condition_and_new_work_toggles() -> void:
	var n := _npc()
	n.hunger = 30.0
	n.stamina = 55.0
	n.health = 80.0
	game.select_npc(n.id)
	var ins := game.inspector
	assert_eq(ins.need_bars[&"hunger"].value, 30.0)
	assert_eq(ins.need_bars[&"stamina"].value, 55.0)
	assert_eq(ins.need_bars[&"health"].value, 80.0)
	assert_eq(ins.condition_label.text, "OK")
	assert_string_contains(ins.state_label.text, String(n.state))
	assert_true(ins.work_checks.has(&"farm"))
	assert_true(ins.work_checks.has(&"cook"))
	(ins.work_checks[&"cook"] as CheckBox).button_pressed = false
	assert_false(n.work_enabled[&"cook"])
	(ins.work_checks[&"farm"] as CheckBox).button_pressed = false
	assert_false(n.work_enabled[&"farm"])
	assert_eq(UiStyle.condition_name(Npc.CONDITION_COLLAPSED), "Collapsed")
	assert_eq(UiStyle.condition_name(Npc.CONDITION_DEAD), "Dead")


func test_bed_picker_assigns_and_auto() -> void:
	var t := _spot(&"bed")
	var bed: String = session.buildings.place(&"bed", t, {&"dirt": 50.0}).data["id"]
	var n := _npc()
	game.select_npc(n.id)
	var opt := game.inspector.bed_option
	assert_eq(opt.item_count, 2, "Auto + 1 bed")
	assert_eq(opt.get_item_text(0), "Auto")
	opt.select(1)
	opt.item_selected.emit(1)
	assert_eq(n.bed_id, bed)
	assert_eq(opt.selected, 1)
	var other := session.colony.all_npcs()[1]
	game.select_npc(other.id)
	assert_string_contains(game.inspector.bed_label(bed), n.nickname, "shows the owner")
	game.select_npc(n.id)
	opt.item_selected.emit(0)
	assert_true(game.assign_bed("").ok, "auto")


func test_schedule_editor_changes_npc_schedule_and_all() -> void:
	var n := _npc()
	game.select_npc(n.id)
	game.inspector.schedule_button.pressed.emit()
	assert_true(game.schedule_editor.visible)
	assert_eq(game.schedule_editor.cells.size(), 24)
	for c in game.schedule_editor.cells:
		assert_gte(c.custom_minimum_size.x, 44.0)
		assert_gte(c.custom_minimum_size.y, 44.0)
	var before := n.schedule[3]
	game.schedule_editor.cells[3].pressed.emit()
	assert_eq(n.schedule[3], ScheduleEditor.next_activity(before), "cycled")
	game.schedule_editor.cells[10].pressed.emit()   # WORK -> SLEEP
	assert_eq(n.schedule[10], Npc.Activity.SLEEP)
	game.schedule_editor.cells[10].pressed.emit()   # SLEEP -> FREE
	assert_eq(n.schedule[10], Npc.Activity.FREE)
	assert_eq(game.schedule_editor.cells[10].text, "F")
	assert_eq(ScheduleEditor.next_activity(Npc.Activity.FREE), Npc.Activity.WORK)
	var r := game.set_schedule_all(n.schedule)
	assert_true(r.ok, str(r))
	for o in session.colony.all_npcs():
		assert_eq(o.schedule, n.schedule)
	var other := session.colony.all_npcs()[1]
	game.select_npc(other.id)
	assert_string_contains(game.schedule_editor.title_label.text, other.nickname, "editor follows selection")
	game.select_npc("")
	assert_false(game.schedule_editor.visible)


func test_colony_overview_lists_npcs_food_deaths_and_selects() -> void:
	_key(KEY_C)
	assert_true(game.overview.visible)
	assert_true(game.toolbar.colony_button.button_pressed)
	game.overview.refresh()
	assert_eq(game.overview.rows.size(), session.colony.count())
	var totals := session.inventory.total_kg_by_material()
	for f in session.materials.foods():
		assert_string_contains(game.overview.food_label.text,
				"%s %.0f kg" % [session.materials.get_def(f).display_name, float(totals.get(f, 0.0))])
	assert_gt(float(totals.get(&"ration", 0.0)), 0.0, "fixture: starting ration crate")
	assert_string_contains(game.overview.deaths_label.text, "Deaths: 0")
	var n := session.colony.all_npcs()[2]
	n.hunger = 12.0
	game.overview.refresh()
	assert_eq((game.overview.rows[n.id]["hunger"] as ProgressBar).value, 12.0)
	(game.overview.rows[n.id]["button"] as Button).pressed.emit()
	assert_eq(game.selected_npc_id, n.id)
	var px := game.scale_config.tile_size_px
	assert_lt(game.camera.position.distance_to(Vector2(n.tile) * px), 4.0 * px)
	_key(KEY_C)
	assert_false(game.overview.visible)


func test_farm_plot_panel_shows_stage_and_growth() -> void:
	var t := _spot(&"farm_plot")
	var id: String = session.buildings.place(&"farm_plot", t, {&"dirt": 50.0}).data["id"]
	game.click_tile(t)
	var bi := game.building_inspector
	assert_true(bi.farm_box.visible)
	assert_false(bi.kitchen_box.visible)
	assert_string_contains(bi.farm_label.text, "empty")
	assert_true(session.farming.plant(id).ok)
	bi.refresh()
	assert_string_contains(bi.farm_label.text, "growing")
	assert_eq(bi.farm_bar.value, session.farming.progress(id) * 100.0)


func test_kitchen_panel_sets_meal_target() -> void:
	var t := _spot(&"kitchen")
	var id: String = session.buildings.place(&"kitchen", t, {&"rock": 100.0}).data["id"]
	game.click_tile(t)
	var bi := game.building_inspector
	assert_true(bi.kitchen_box.visible)
	assert_false(bi.farm_box.visible)
	assert_eq(bi.kitchen_target.value, session.kitchens.target_kg(id))
	assert_gte(bi.kitchen_target.custom_minimum_size.y, 44.0)
	bi.kitchen_target.value = 24.0
	assert_eq(session.kitchens.target_kg(id), 24.0)
	assert_string_contains(bi.kitchen_label.text, "Meals in stock")


func test_build_menu_has_food_buildings_and_soil_reason() -> void:
	assert_true(game.build_menu.entry_buttons.has(&"farm_plot"))
	assert_true(game.build_menu.entry_buttons.has(&"kitchen"))
	assert_string_contains((game.build_menu.entry_buttons[&"farm_plot"] as Button).text, "floor")
	# Concrete floor: the farm plot needs soil.
	var t := _spot(&"farm_plot")
	assert_true(session.grid.apply_edit(Rect2i(t, Vector2i(2, 1)), WorldGrid.Edit.BUILD_WALL).ok)
	var o := t + Vector2i.UP
	game.start_placement(&"farm_plot")
	var r := game.tools.update_preview(o)
	assert_false(r.ok)
	assert_eq(r.code, &"needs_soil")
	assert_string_contains(r.message, "floor")
	var placed := game.tools.place_at(o)
	assert_eq(game.toast.text, placed.message, "reason shown in the toast")


func test_m4a_panels_do_not_overlap_at_1280x720() -> void:
	var win := get_tree().root
	var old_size := win.size
	win.size = Vector2i(1280, 720)
	await wait_process_frames(2)
	assert_eq(get_viewport().get_visible_rect().size, Vector2(1280, 720), "fixture: test viewport")
	var n := _npc()
	game.select_npc(n.id)
	game.set_schedule_visible(true)
	await wait_process_frames(2)
	var vp := Rect2(Vector2.ZERO, Vector2(1280, 720))
	var a := {
		"top-left": (game.toolbar.get_parent() as Control).get_global_rect(),
		"alerts": game.alerts_panel.get_global_rect(),
		"inspector": game.inspector.get_global_rect(),
		"schedule": game.schedule_editor.get_global_rect(),
		"debug hud": game.debug_hud.get_global_rect(),
	}
	_assert_disjoint(a, vp)
	game.set_overview_visible(true)
	await wait_process_frames(2)
	assert_false(game.schedule_editor.visible, "overview and schedule share the centre")
	var b := {
		"top-left+overview": (game.toolbar.get_parent() as Control).get_global_rect(),
		"alerts": game.alerts_panel.get_global_rect(),
		"inspector": game.inspector.get_global_rect(),
		"debug hud": game.debug_hud.get_global_rect(),
	}
	_assert_disjoint(b, vp)
	game.set_overview_visible(false)
	var t := _spot(&"kitchen")
	session.buildings.place(&"kitchen", t, {&"rock": 100.0})
	game.click_tile(t)
	game.open_build_menu()
	await wait_process_frames(2)
	var c := {
		"top-left+menu": (game.toolbar.get_parent() as Control).get_global_rect(),
		"alerts": game.alerts_panel.get_global_rect(),
		"building inspector": game.building_inspector.get_global_rect(),
		"debug hud": game.debug_hud.get_global_rect(),
	}
	_assert_disjoint(c, vp)
	win.size = old_size


func _assert_disjoint(rects: Dictionary, vp: Rect2) -> void:
	var names := rects.keys()
	for i in names.size():
		var ra: Rect2 = rects[names[i]]
		assert_true(vp.encloses(ra), "%s %s on screen" % [names[i], ra])
		for j in range(i + 1, names.size()):
			var rb: Rect2 = rects[names[j]]
			assert_false(ra.intersects(rb), "%s %s overlaps %s %s" % [names[i], ra, names[j], rb])


## Tick of a time of day on Day 1 (worlds start at 06:00).
static func _tick_at(hour: float) -> int:
	var h := hour if hour >= GameTime.START_HOUR else hour + 24.0
	return int(round((h - GameTime.START_HOUR) * GameTime.TICKS_PER_HOUR))


## M4A-QA-5: the world darkens at night, smoothly, and the HUD does not.
func test_day_night_tint() -> void:
	assert_true(game.day_tint is CanvasModulate)
	var noon := GameScreen.tint_for_tick(_tick_at(12.0))
	var midnight := GameScreen.tint_for_tick(_tick_at(0.0))
	assert_eq(noon, Color(1, 1, 1), "no tint at noon")
	assert_ne(noon, midnight)
	assert_lt(midnight.v, noon.v, "darker at night")
	assert_gt(midnight.v, 0.5, "night stays readable")
	# Smooth across dusk 18:00-20:00: many distinct steps, none large.
	var prev := GameScreen.tint_for_tick(_tick_at(18.0))
	var distinct := 0
	for m in range(10, 121, 10):
		var c := GameScreen.tint_for_tick(_tick_at(18.0 + m / 60.0))
		var step := absf(c.r - prev.r) + absf(c.g - prev.g) + absf(c.b - prev.b)
		assert_lt(step, 0.2, "smooth at 18:00 + %d min" % m)
		if step > 0.0001:
			distinct += 1
		prev = c
	assert_eq(distinct, 12, "changes at every sample across dusk")
	assert_eq(prev, GameScreen.TINT_NIGHT, "fully night at 20:00")
	assert_eq(GameScreen.tint_for_tick(_tick_at(7.0)), Color(1, 1, 1), "day again after dawn")
	assert_eq(GameScreen.tint_for_tick(_tick_at(12.0) + GameTime.TICKS_PER_DAY), noon, "repeats daily")
	# Applied to the world canvas each frame; HUD panels live on CanvasLayers.
	session.clock.tick_index = _tick_at(0.0)
	await wait_process_frames(1)
	assert_eq(game.day_tint.color, midnight)
	assert_true(game.alerts_panel.get_parent() is CanvasLayer, "HUD not tinted")
