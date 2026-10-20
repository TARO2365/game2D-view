extends GutTest

const FS := preload("res://tests/helpers/fs_util.gd")
const GAME := preload("res://scenes/game.tscn")

var root: String
var slots: WorldSlots
var session: WorldSession
var game: GameScreen


func before_each() -> void:
	root = FS.temp_root("game")
	slots = WorldSlots.new(TileRegistry.load_default(), root)
	session = slots.create_world("Game Test", 5, &"small").data["session"]
	game = GAME.instantiate()
	game.setup(session, slots, load("res://data/config/scale_config.tres"))
	add_child_autofree(game)
	await wait_process_frames(2)


func after_each() -> void:
	FS.rm_rf(root)


func _underground_rect() -> Rect2i:
	var x := 100
	return Rect2i(x, session.grid.surface_y[x] + 2, 4, 3)


func test_boots_and_streams_chunks() -> void:
	assert_gt(game.world_view.loaded_chunk_count(), 0)
	assert_true(game.camera.is_current())
	assert_string_contains(game.debug_hud.text, "Game Test")


func test_dig_tool_places_orders_not_terrain() -> void:
	var before := session.grid.world_hash()
	game.set_tool(ToolController.Tool.DIG)
	var r := game.tools.apply_rect(_underground_rect())
	assert_true(r.ok, str(r))
	assert_eq(session.designations.count(), 12)
	assert_eq(session.grid.world_hash(), before, "D-015")


func test_dev_instant_edit_changes_terrain() -> void:
	var before := session.grid.world_hash()
	assert_true(game.tools.set_dev_instant(true).ok)
	game.set_tool(ToolController.Tool.DIG)
	assert_true(game.tools.apply_rect(_underground_rect()).ok)
	assert_ne(session.grid.world_hash(), before)


func test_cancel_and_select_tools() -> void:
	game.set_tool(ToolController.Tool.DIG)
	game.tools.apply_rect(_underground_rect())
	game.set_tool(ToolController.Tool.CANCEL)
	assert_true(game.tools.apply_rect(_underground_rect()).ok)
	assert_eq(session.designations.count(), 0)
	game.set_tool(ToolController.Tool.SELECT)
	assert_eq(game.tools.apply_rect(_underground_rect()).code, &"no_tool")


func test_toolbar_switches_tool_and_pan_mode() -> void:
	game.toolbar.get_tool_button(ToolController.Tool.DIG).pressed.emit()
	assert_eq(game.tools.tool, ToolController.Tool.DIG)
	assert_false(game.camera.left_drag_pans)
	game.toolbar.get_tool_button(ToolController.Tool.SELECT).pressed.emit()
	assert_true(game.camera.left_drag_pans)


func test_speed_bar_controls_world_clock() -> void:
	game.speed_bar.get_button(3).pressed.emit()
	assert_eq(session.clock.speed, 3)
	game.speed_bar.get_button(0).pressed.emit()
	assert_true(session.clock.is_paused())


func test_save_and_quit() -> void:
	assert_true(game.save_now(SaveService.Kind.MANUAL).ok)
	watch_signals(game)
	game.quit_to_menu()
	assert_signal_emitted(game, "quit_requested")
	assert_true(FileAccess.file_exists(slots.world_dir(session.world_id()).path_join("autosave.save")))


func test_orders_survive_save_and_load() -> void:
	game.set_tool(ToolController.Tool.DIG)
	game.tools.apply_rect(_underground_rect())
	game.save_now(SaveService.Kind.MANUAL)
	var r := slots.load_world(session.world_id())
	assert_true(r.ok)
	assert_eq(r.data["session"].designations.count(), 12)
