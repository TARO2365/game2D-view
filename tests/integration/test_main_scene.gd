extends GutTest

const MAIN := preload("res://scenes/main.tscn")

var main: Node


func before_each() -> void:
	main = MAIN.instantiate()
	add_child_autofree(main)
	await wait_process_frames(1)


func test_scene_boots_with_clock_and_config() -> void:
	assert_not_null(main.clock)
	assert_not_null(main.scale_config)
	assert_eq(main.scale_config.tile_size_px, 64)


func test_speed_bar_has_four_buttons_and_reflects_default() -> void:
	var bar: SpeedBar = main.get_node("UI/SpeedBar")
	for s in [0, 1, 2, 3]:
		assert_not_null(bar.get_button(s), "button %d" % s)
	assert_true(bar.get_button(1).button_pressed)


func test_pressing_buttons_issues_commands() -> void:
	var bar: SpeedBar = main.get_node("UI/SpeedBar")
	bar.get_button(3).pressed.emit()
	assert_eq(main.clock.speed, 3)
	assert_true(bar.get_button(3).button_pressed)
	assert_false(bar.get_button(1).button_pressed)
	bar.get_button(0).pressed.emit()
	assert_true(main.clock.is_paused())


func test_clock_advances_while_running_and_stops_when_paused() -> void:
	await wait_seconds(0.5)
	assert_gt(main.clock.tick_index, 0)
	main.clock.set_speed(0)
	var frozen: int = main.clock.tick_index
	await wait_seconds(0.3)
	assert_eq(main.clock.tick_index, frozen)


func test_ui_reflects_external_speed_change() -> void:
	var bar: SpeedBar = main.get_node("UI/SpeedBar")
	main.clock.set_speed(2)
	assert_true(bar.get_button(2).button_pressed)
