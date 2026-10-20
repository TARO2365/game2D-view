extends GutTest


func test_clamp_center_inside_world() -> void:
	var world := Vector2(1000, 800)
	var view := Vector2(200, 100)
	assert_eq(CameraController.clamp_center(Vector2(500, 400), view, world), Vector2(500, 400))
	assert_eq(CameraController.clamp_center(Vector2(-50, -50), view, world), Vector2(100, 50))
	assert_eq(CameraController.clamp_center(Vector2(5000, 5000), view, world), Vector2(900, 750))


func test_clamp_center_when_view_larger_than_world() -> void:
	assert_eq(CameraController.clamp_center(Vector2(10, 10), Vector2(2000, 50), Vector2(1000, 800)),
			Vector2(500, 25))


func test_zoom_is_clamped() -> void:
	var cam := CameraController.new()
	cam.setup(Vector2(64 * 512, 64 * 256))
	add_child_autofree(cam)
	cam.zoom_by_center(1000.0)
	assert_eq(cam.zoom.x, CameraController.ZOOM_MAX)
	cam.zoom_by_center(0.00001)
	assert_eq(cam.zoom.x, CameraController.ZOOM_MIN)
	var v := cam.view_rect_px()
	assert_true(Rect2(Vector2.ZERO, cam.world_size_px).encloses(v), "view stays inside world")


func _key(code: Key, pressed: bool) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.pressed = pressed
	Input.parse_input_event(e)
	Input.flush_buffered_events()


## Regression: Ctrl+S (save) used to also pan the camera down (found in Web smoke test).
func test_ctrl_shortcut_does_not_pan() -> void:
	var cam := CameraController.new()
	cam.setup(Vector2(64 * 512, 64 * 256))
	add_child_autofree(cam)
	cam.position = Vector2(5000, 5000)
	_key(KEY_S, true)
	cam._process(0.5)
	assert_ne(cam.position, Vector2(5000, 5000), "plain S pans")
	var moved := cam.position
	_key(KEY_CTRL, true)
	cam._process(0.5)
	assert_eq(cam.position, moved, "Ctrl+S does not pan")
	_key(KEY_S, false)
	_key(KEY_CTRL, false)


func test_drag_rect_normalised() -> void:
	assert_eq(ToolController.rect_from_tiles(Vector2i(5, 9), Vector2i(2, 3)), Rect2i(2, 3, 4, 7))
	assert_eq(ToolController.rect_from_tiles(Vector2i(4, 4), Vector2i(4, 4)), Rect2i(4, 4, 1, 1))
