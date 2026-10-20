extends GutTest
## End-to-end flow through the real main scene: menu -> new world -> game ->
## menu -> load. Uses a temporary worlds folder.

const FS := preload("res://tests/helpers/fs_util.gd")
const MAIN := preload("res://scenes/main.tscn")

var root: String
var app: Node


func before_each() -> void:
	root = FS.temp_root("app")
	app = MAIN.instantiate()
	app.worlds_root = root
	add_child_autofree(app)
	await wait_process_frames(1)


func after_each() -> void:
	FS.rm_rf(root)


func _menu() -> MainMenu:
	return app.current_screen as MainMenu


func _create(world_name: String) -> CommandResult:
	var menu := _menu()
	menu.open_new_world_dialog()
	menu.name_edit.text = world_name
	menu.seed_edit.text = "77"
	menu.size_option.select(0)  # small
	return menu.submit_new_world()


func test_starts_in_menu_with_no_worlds() -> void:
	assert_not_null(_menu())
	assert_false(_menu().new_world_button.disabled)


func test_new_world_dialog_prefills_name() -> void:
	_menu().open_new_world_dialog()
	assert_true(_menu().new_world_overlay.visible)
	assert_eq(_menu().name_edit.text, "World 1")


func test_create_play_quit_and_continue() -> void:
	assert_true(_create("Bunker A").ok)
	await wait_process_frames(1)
	var game := app.current_screen as GameScreen
	assert_not_null(game, "game screen shown")
	assert_eq(game.session.meta["name"], "Bunker A")
	assert_eq(game.session.meta["seed"], 77)
	game.quit_to_menu()
	await wait_process_frames(1)
	assert_not_null(_menu(), "back to menu")
	var worlds: Array[Dictionary] = app.slots.list_worlds()
	assert_eq(worlds.size(), 1)
	assert_true(_menu().play_world(worlds[0]["id"]).ok)
	await wait_process_frames(1)
	assert_not_null(app.current_screen as GameScreen, "loaded world plays")


func test_limit_disables_new_world_and_delete_reenables() -> void:
	for n in ["A", "B", "C"]:
		assert_true(_create(n).ok)
		await wait_process_frames(1)
		(app.current_screen as GameScreen).quit_to_menu()
		await wait_process_frames(1)
	assert_true(_menu().new_world_button.disabled)
	assert_string_contains(_menu().status_label.text, "World limit")
	var id: String = app.slots.list_worlds()[0]["id"]
	_menu().request_delete(id)
	assert_true(_menu().confirm_delete().ok)
	assert_false(_menu().new_world_button.disabled)


func test_duplicate_name_shows_error() -> void:
	assert_true(_create("Same").ok)
	await wait_process_frames(1)
	(app.current_screen as GameScreen).quit_to_menu()
	await wait_process_frames(1)
	var r := _create("same")
	assert_false(r.ok)
	assert_string_contains(_menu().status_label.text, "already exists")
