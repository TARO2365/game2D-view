extends GutTest
## M3 UI: build menu, placement preview/orders, deconstruct tool, room
## overlay, building inspector + crate filter, art hooks. Real GameScreen on
## a real (temp) world.

const FS := preload("res://tests/helpers/fs_util.gd")
const GAME := preload("res://scenes/game.tscn")

var root: String
var slots: WorldSlots
var session: WorldSession
var game: GameScreen


func before_each() -> void:
	root = FS.temp_root("ui_bld")
	slots = WorldSlots.new(TileRegistry.load_default(), root)
	session = slots.create_world("UI Buildings", 5, &"small").data["session"]
	session.clock.set_speed(0)
	game = GAME.instantiate()
	game.setup(session, slots, load("res://data/config/scale_config.tres"))
	add_child_autofree(game)
	await wait_process_frames(2)


func after_each() -> void:
	FS.rm_rf(root)


## A surface floor tile near the camera where `key` fits and no NPC stands.
func _crate_spot(key: StringName = &"crate") -> Vector2i:
	var mid := session.grid.width / 2
	for off in range(4, 60):
		for x in [mid + off, mid - off]:
			var t := Vector2i(x, session.grid.surface_y[x] - 1)
			if session.buildings.can_place(key, t).ok and session.colony.npc_at(t) == null \
					and session.colony.npc_at(t + Vector2i.RIGHT) == null:
				return t
	fail_test("no spot for %s" % key)
	return Vector2i.ZERO


func _underground() -> Vector2i:
	var x := session.grid.width / 2 + 10
	return Vector2i(x, session.grid.surface_y[x] + 3)


func _show_all(view: Node2D, around: Vector2i) -> void:
	var px := float(game.scale_config.tile_size_px)
	view.call("set_visible_rect", Rect2(Vector2(around) * px - Vector2(640, 360), Vector2(1280, 720)))


func test_build_menu_lists_all_defs() -> void:
	game.toolbar.get_tool_button(ToolController.Tool.PLACE_BUILDING).pressed.emit()
	assert_true(game.build_menu.visible)
	var defs := session.buildings.registry.all_defs()
	assert_eq(game.build_menu.entry_buttons.size(), defs.size())
	for d in defs:
		var b: Button = game.build_menu.entry_buttons[d.key]
		assert_string_contains(b.text, d.display_name)
		assert_string_contains(b.text, "%d×%d" % [d.size.x, d.size.y])
		assert_string_contains(b.text, "%.0f kg" % d.kg)
		assert_gte(b.custom_minimum_size.y, 44.0)
	game.build_menu.entry_buttons[&"bed"].pressed.emit()
	assert_eq(game.tools.tool, ToolController.Tool.PLACE_BUILDING)
	assert_eq(game.tools.place_key, &"bed")
	assert_false(game.build_menu.visible, "menu closes on choice")
	assert_false(game.camera.left_drag_pans)


func test_placement_orders_building_and_reports_failures() -> void:
	var t := _crate_spot()
	game.set_priority(7)
	assert_true(game.start_placement(&"crate").ok)
	assert_true(game.tools.update_preview(t).ok, "green preview")
	var r := game.tools.place_at(t)
	assert_true(r.ok, str(r))
	assert_eq(session.build_orders.count(), 1)
	assert_eq(session.build_orders.order_at(t)["priority"], 7, "selector priority used")
	assert_false(game.tools.update_preview(t).ok, "red preview: already ordered")
	var again := game.tools.place_at(t)
	assert_false(again.ok)
	assert_eq(again.code, &"overlaps_order")
	var bad := game.tools.place_at(_underground())
	assert_false(bad.ok)
	assert_eq(game.toast.text, bad.message)
	assert_eq(session.build_orders.count(), 1)


func test_placement_exits_with_escape_and_right_click() -> void:
	game.start_placement(&"table")
	var e := InputEventKey.new()
	e.keycode = KEY_ESCAPE
	e.pressed = true
	game._unhandled_key_input(e)
	assert_eq(game.tools.tool, ToolController.Tool.SELECT)
	assert_eq(game.tools.place_key, &"")
	game.start_placement(&"table")
	game.tools.cancel_requested.emit()
	assert_eq(game.tools.tool, ToolController.Tool.SELECT)


func test_priority_and_cancel_apply_to_building_orders() -> void:
	var t := _crate_spot()
	game.start_placement(&"crate")
	assert_true(game.tools.place_at(t).ok)
	game.set_tool(ToolController.Tool.PRIORITY)
	game.set_priority(2)
	var r := game.tools.apply_rect(Rect2i(t, Vector2i.ONE))
	assert_true(r.ok, str(r))
	assert_eq(session.build_orders.order_at(t)["priority"], 2)
	assert_true(game.overlay.show_priorities)
	game.set_tool(ToolController.Tool.CANCEL)
	assert_true(game.tools.apply_rect(Rect2i(t - Vector2i.ONE, Vector2i(3, 3))).ok)
	assert_eq(session.build_orders.count(), 0)


func test_deconstruct_tool_designates() -> void:
	var t := _crate_spot()
	assert_true(session.grid.apply_edit(Rect2i(t, Vector2i.ONE), WorldGrid.Edit.BUILD_WALL).ok)
	game.toolbar.get_tool_button(ToolController.Tool.DECONSTRUCT).pressed.emit()
	assert_eq(game.tools.tool, ToolController.Tool.DECONSTRUCT)
	assert_true(game.toolbar.priority_box.visible)
	var r := game.tools.apply_rect(Rect2i(t, Vector2i.ONE))
	assert_true(r.ok, str(r))
	assert_eq(session.designations.get_kind(t), DesignationMap.Kind.DECONSTRUCT)


func test_buildings_render_with_crate_fill() -> void:
	var t := _crate_spot()
	var r := session.buildings.place(&"crate", t, {&"rock": 50.0})
	assert_true(r.ok, str(r))
	_show_all(game.building_view, t)
	await wait_process_frames(2)
	assert_eq(game.building_view.drawn_count, 1)
	assert_eq(game.building_view.crate_fill(r.data["id"], &"crate"), 0.0)
	assert_eq(game.building_view.crate_fill(r.data["id"], &"bed"), -1.0)


## Builds a closed underground room with instant edits and a bed in it.
func _make_bedroom() -> Vector2i:
	var x := session.grid.width / 2 + 20
	var outer := Rect2i(x, session.grid.surface_y[x] + 8, 6, 5)
	session.grid.apply_edit(outer, WorldGrid.Edit.DIG)
	assert_true(session.grid.apply_edit(outer, WorldGrid.Edit.BUILD_WALL).ok)
	var inner := Rect2i(outer.position + Vector2i.ONE, outer.size - Vector2i(2, 2))
	assert_true(session.grid.apply_edit(inner, WorldGrid.Edit.DECONSTRUCT_WALL).ok)
	var bed_origin := Vector2i(inner.position.x, inner.end.y - 1)
	var r := session.buildings.place(&"bed", bed_origin, {&"rock": 50.0})
	assert_true(r.ok, str(r))
	return inner.position


func test_room_overlay_shows_constructed_room() -> void:
	var inside := _make_bedroom()
	var room := session.rooms.room_at(inside)
	assert_false(room.is_empty(), "RoomMap found it")
	assert_eq(room["type"], &"bedroom")
	assert_false(game.room_overlay.visible, "off by default")
	var e := InputEventKey.new()
	e.keycode = KEY_R
	e.pressed = true
	game._unhandled_key_input(e)
	assert_true(game.room_overlay.visible, "R toggles")
	assert_true(game.toolbar.rooms_button.button_pressed)
	_show_all(game.room_overlay, inside)
	game.room_overlay.queue_redraw()
	await wait_process_frames(2)
	assert_has(game.room_overlay.drawn_labels, "Bedroom")
	assert_eq(RoomOverlay.describe(room), "Bedroom, %d tiles" % room["size"])
	game.toolbar.rooms_button.button_pressed = false
	assert_false(game.room_overlay.visible)


func test_click_building_shows_crate_panel_and_filter() -> void:
	var t := _crate_spot()
	var id: String = session.buildings.place(&"crate", t, {&"dirt": 50.0}).data["id"]
	game.click_tile(t)
	assert_eq(game.selected_building_id, id)
	assert_true(game.building_inspector.visible)
	assert_false(game.inspector.visible)
	assert_eq(game.building_inspector.title_label.text, "Storage Crate")
	assert_true(game.building_inspector.filter_box.visible)
	assert_string_contains(game.building_inspector.contents_label.text, "0 / 2000 kg")
	var checks := game.building_inspector.filter_checks
	assert_eq(checks.size(), 5, "dirt, rock, iron, gold, crystal")
	for m in checks:
		assert_true((checks[m] as CheckBox).button_pressed, "empty filter = all ticked")
	(checks[&"rock"] as CheckBox).button_pressed = false
	var f := session.crates.get_filter(id)
	assert_eq(f.size(), 4)
	assert_false(f.has(&"rock"))
	for m in [&"dirt", &"iron_ore", &"gold_ore"]:
		(checks[m] as CheckBox).button_pressed = false
	assert_eq(session.crates.get_filter(id), [&"crystal"] as Array[StringName])
	(checks[&"crystal"] as CheckBox).button_pressed = false
	assert_eq(session.crates.get_filter(id), [&"crystal"] as Array[StringName], "cannot untick the last one")
	assert_true((checks[&"crystal"] as CheckBox).button_pressed)
	assert_eq(game.toast.text, "A crate must accept at least one material")
	(checks[&"rock"] as CheckBox).button_pressed = true
	assert_eq(session.crates.get_filter(id).size(), 2)


func test_building_panel_deconstruct() -> void:
	var t := _crate_spot(&"bed")
	assert_true(session.buildings.place(&"bed", t, {&"dirt": 50.0}).ok)
	game.click_tile(t + Vector2i.RIGHT)  # any footprint tile selects it
	assert_false(game.selected_building_id.is_empty())
	assert_eq(game.building_inspector.title_label.text, "Bed")
	assert_false(game.building_inspector.filter_box.visible, "no filter for a bed")
	game.building_inspector.deconstruct_button.pressed.emit()
	assert_eq(session.designations.get_kind(t), DesignationMap.Kind.DECONSTRUCT)
	game.click_tile(Vector2i(1, 1))
	assert_false(game.building_inspector.visible, "click elsewhere deselects")


func test_hud_shows_building_and_room_counts() -> void:
	_make_bedroom()
	await wait_process_frames(1)
	assert_string_contains(game.debug_hud.text, "buildings 1")
	assert_string_contains(game.debug_hud.text, "rooms %d" % session.rooms.room_count())


func test_panels_do_not_overlap_at_1280x720() -> void:
	var t := _crate_spot()
	session.buildings.place(&"crate", t, {&"dirt": 50.0})
	game.click_tile(t)
	game.open_build_menu()
	await wait_process_frames(2)
	var tb := game.toolbar.get_global_rect()
	var bi := game.building_inspector.get_global_rect()
	var bm := game.build_menu.get_global_rect()
	assert_false(tb.intersects(bi), "toolbar %s vs inspector %s" % [tb, bi])
	assert_false(bm.intersects(bi), "build menu %s vs inspector %s" % [bm, bi])
	assert_false(game.debug_hud.get_global_rect().intersects(bi), "HUD %s vs inspector %s" % [game.debug_hud.get_global_rect(), bi])
	assert_lte(bi.end.y, 720.0, "inspector fits on screen")
	assert_lte(tb.end.x, 1280.0 - 360.0, "toolbar left of the HUD column")


func test_art_hooks_use_production_files_when_present() -> void:
	var old := ArtLibrary.base_dir
	var art := FS.temp_root("art")
	DirAccess.make_dir_recursive_absolute(art.path_join("backgrounds"))
	DirAccess.make_dir_recursive_absolute(art.path_join("buildings"))
	var img := Image.create(256, 64, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.2, 0.15, 0.1))
	img.save_png(art.path_join("backgrounds/backwall_dug.png"))
	var crate := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	crate.fill(Color.BROWN)
	crate.save_png(art.path_join("buildings/building_crate.png"))
	ArtLibrary.base_dir = art
	ArtLibrary.clear_cache()
	assert_not_null(game.world_view.backwall_texture())
	assert_null(game.world_view.sky_texture(), "missing file -> flat colour fallback")
	assert_not_null(game.building_view.texture_for(&"crate"))
	assert_null(game.building_view.texture_for(&"bed"))
	game.world_view.queue_redraw()
	await wait_process_frames(1)
	ArtLibrary.base_dir = old
	ArtLibrary.clear_cache()
	FS.rm_rf(art)
	assert_null(game.building_view.texture_for(&"crate"), "no production art in the repo yet")
