extends GutTest
## M2 UI: NPC views, selection, inspector and NPC quick commands, driven
## through a real GameScreen built from a real (temp) world.

const FS := preload("res://tests/helpers/fs_util.gd")
const GAME := preload("res://scenes/game.tscn")

var root: String
var slots: WorldSlots
var session: WorldSession
var game: GameScreen


func before_each() -> void:
	root = FS.temp_root("ui_npcs")
	slots = WorldSlots.new(TileRegistry.load_default(), root)
	session = slots.create_world("UI NPCs", 5, &"small").data["session"]
	session.clock.set_speed(0)  # tests drive state explicitly
	game = GAME.instantiate()
	game.setup(session, slots, load("res://data/config/scale_config.tres"))
	add_child_autofree(game)
	await wait_process_frames(2)


func after_each() -> void:
	FS.rm_rf(root)


func _first() -> Npc:
	return session.colony.all_npcs()[0]


static func _has_thai(s: String) -> bool:
	for i in s.length():
		var c := s.unicode_at(i)
		if c >= 0x0E00 and c <= 0x0E7F:
			return true
	return false


func test_view_per_colonist_at_feet_position() -> void:
	assert_eq(session.colony.count(), Colony.START_NPCS)
	assert_eq(game.npc_layer.view_count(), session.colony.count())
	for n in session.colony.all_npcs():
		var v := game.npc_layer.get_view(n.id)
		assert_not_null(v, n.id)
		var px := game.scale_config.tile_size_px
		assert_almost_eq(v.position, Vector2((n.tile.x + 0.5) * px, (n.tile.y + 1) * px), Vector2.ONE * 0.5,
				"D-003 pivot: bottom-centre of the feet tile")
		assert_eq(v.label.text, n.nickname)


func test_click_on_npc_body_selects_and_shows_thai_names() -> void:
	var n := _first()
	game.click_tile(n.tile + Vector2i(0, -2))  # head tile of the 3-tile body
	assert_eq(game.selected_npc_id, n.id)
	assert_true(game.inspector.visible)
	assert_true(game.npc_layer.get_view(n.id).selected, "highlight ring")
	assert_eq(game.inspector.full_name_label.text, n.full_name)
	assert_true(_has_thai(game.inspector.full_name_label.text), "Thai full name shown")
	assert_string_contains(game.inspector.nickname_label.text, n.nickname)
	assert_string_contains(game.inspector.carry_label.text, "nothing")


func test_click_elsewhere_deselects() -> void:
	var n := _first()
	game.click_tile(n.tile)
	game.click_tile(Vector2i(1, 1))  # sky corner, no NPC
	assert_eq(game.selected_npc_id, "")
	assert_false(game.inspector.visible)
	assert_false(game.npc_layer.get_view(n.id).selected)


func test_move_here_calls_command_move() -> void:
	var a := session.colony.all_npcs()[0]
	var b := session.colony.all_npcs()[1]
	game.select_npc(a.id)
	game.inspector.move_button.pressed.emit()
	assert_true(game.move_pending)
	var r := game.click_tile(b.tile)  # a standable tile
	assert_true(r.ok, str(r))
	assert_false(game.move_pending, "one click only")
	assert_ne(a.command_target, Npc.NO_TILE)
	assert_eq(game.selected_npc_id, a.id, "selection kept")


func test_move_here_failure_is_toasted() -> void:
	game.select_npc(_first().id)
	game.request_move()
	var r := game.click_tile(Vector2i(-50, -50))
	assert_false(r.ok)
	assert_eq(game.toast.text, r.message)
	assert_eq(_first().command_target, Npc.NO_TILE)


func test_escape_cancels_move_mode() -> void:
	game.select_npc(_first().id)
	game.request_move()
	var e := InputEventKey.new()
	e.keycode = KEY_ESCAPE
	e.pressed = true
	game._unhandled_key_input(e)
	assert_false(game.move_pending)
	assert_eq(game.selected_npc_id, _first().id, "first Esc only cancels the move")
	game.request_move()
	var rc := InputEventMouseButton.new()
	rc.button_index = MOUSE_BUTTON_RIGHT
	rc.pressed = true
	game._unhandled_input(rc)
	assert_false(game.move_pending, "right-click cancels")


func test_stop_calls_command_stop() -> void:
	var a := session.colony.all_npcs()[0]
	var b := session.colony.all_npcs()[1]
	game.select_npc(a.id)
	assert_true(game.move_selected_to(b.tile).ok)
	game.inspector.stop_button.pressed.emit()
	assert_eq(a.command_target, Npc.NO_TILE)


func test_stop_without_selection_reports_failure() -> void:
	var r := game.stop_selected()
	assert_false(r.ok)
	assert_eq(game.toast.text, r.message)
	assert_false(game.request_move().ok)


func test_work_toggles_change_npc() -> void:
	var n := _first()
	game.select_npc(n.id)
	var cb: CheckBox = game.inspector.work_checks[&"dig"]
	assert_true(cb.button_pressed)
	cb.button_pressed = false
	assert_false(n.work_enabled[&"dig"])
	assert_true(n.work_enabled[&"haul"])
	(game.inspector.work_checks[&"haul"] as CheckBox).button_pressed = false
	assert_false(n.work_enabled[&"haul"])
	cb.button_pressed = true
	assert_true(n.work_enabled[&"dig"])


func test_inspector_shows_carried_item() -> void:
	var n := _first()
	var id := session.inventory.spawn_ground(&"rock", 50.0, n.tile)
	assert_true(session.inventory.pick_up(id, n.id).ok)
	game.select_npc(n.id)
	assert_string_contains(game.inspector.carry_label.text, "50 kg")
	await wait_process_frames(1)
	assert_true(game.npc_layer.get_view(n.id).inventory.carried_by(n.id) != null)


func test_debug_spawn_adds_view() -> void:
	var t := _first().tile + Vector2i(3, 0)
	var r := game.spawn_debug_npc(t)
	assert_true(r.ok, str(r))
	assert_eq(session.colony.count(), Colony.START_NPCS + 1)
	await wait_process_frames(1)
	assert_eq(game.npc_layer.view_count(), Colony.START_NPCS + 1)
	assert_false(game.spawn_debug_npc(Vector2i(-1, -1)).ok)


func test_views_follow_movement_smoothly() -> void:
	var a := session.colony.all_npcs()[0]
	var b := session.colony.all_npcs()[1]
	var v := game.npc_layer.get_view(a.id)
	var start := v.position
	assert_true(session.colony.command_move(a.id, b.tile).ok)
	session.clock.set_speed(3)
	await wait_seconds(1.0)
	session.clock.set_speed(0)
	assert_ne(v.position, start, "view moved with the NPC")
	assert_lt(v.position.distance_to(v.target_position()), 3.0 * game.scale_config.tile_size_px)


func test_hud_shows_npc_and_job_counts() -> void:
	await wait_process_frames(1)
	assert_string_contains(game.debug_hud.text, "NPCs %d" % Colony.START_NPCS)
	assert_string_contains(game.debug_hud.text, "jobs ")


func test_inspector_does_not_overlap_toolbar() -> void:
	game.select_npc(_first().id)
	await wait_process_frames(2)
	var tb := game.toolbar.get_global_rect()
	var ins := game.inspector.get_global_rect()
	assert_false(tb.intersects(ins), "toolbar %s vs inspector %s" % [tb, ins])
	assert_false(game.debug_hud.get_global_rect().intersects(ins), "debug HUD above inspector")
	for t in ToolController.Tool.values():
		assert_gte(game.toolbar.get_tool_button(t).size.y, 44.0, "touch target")
