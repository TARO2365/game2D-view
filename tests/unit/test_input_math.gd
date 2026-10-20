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


# --- M2 presentation helpers ----------------------------------------------

func test_npc_feet_position_interpolates_bottom_centre() -> void:
	assert_eq(NpcView.feet_position(Vector2i(2, 5), Vector2i(2, 5), 0.0, 64), Vector2(160, 384))
	assert_eq(NpcView.feet_position(Vector2i(2, 5), Vector2i(3, 5), 0.5, 64), Vector2(192, 384))
	assert_eq(NpcView.feet_position(Vector2i(2, 5), Vector2i(3, 4), 2.0, 64), Vector2(224, 320), "clamped")


func test_smooth_toward_approaches_and_snaps() -> void:
	var p := NpcView.smooth_toward(Vector2.ZERO, Vector2(10, 0), 0.016, 18.0, 192.0)
	assert_gt(p.x, 0.0)
	assert_lt(p.x, 10.0)
	assert_eq(NpcView.smooth_toward(Vector2.ZERO, Vector2(500, 0), 0.016, 18.0, 192.0), Vector2(500, 0), "snap")
	var q := Vector2.ZERO
	for i in 120:
		q = NpcView.smooth_toward(q, Vector2(10, 0), 1.0 / 60.0, 18.0, 192.0)
	assert_almost_eq(q.x, 10.0, 0.01, "converges within 2 s")


func test_npc_colors_are_distinct_and_stable() -> void:
	var seen: Array[Color] = []
	for i in range(1, 11):
		var c := NpcView.color_for_id("npc:%d" % i)
		assert_eq(c, NpcView.color_for_id("npc:%d" % i), "stable")
		for s in seen:
			assert_gt(absf(s.h - c.h) + absf(s.s - c.s) + absf(s.v - c.v), 0.02, "distinct")
		seen.append(c)


func test_material_color_from_tile_defs() -> void:
	var reg := TileRegistry.load_default()
	assert_eq(NpcView.material_color(reg, &"rock"), reg.get_def(TileRegistry.ROCK).placeholder_color)
	assert_eq(NpcView.material_color(reg, &"no_such"), Color.MAGENTA)


func test_item_pile_offsets_unique_and_stacked() -> void:
	var seen: Dictionary = {}
	for i in ItemView.MAX_PILE_SHOWN:
		var o := ItemView.pile_offset(i, 10.0)
		assert_false(seen.has(o), "slot %d unique" % i)
		seen[o] = true
		assert_lte(o.y, 0.0, "never below the floor")
	assert_eq(ItemView.pile_offset(0, 10.0).y, 0.0)
	assert_lt(ItemView.pile_offset(5, 10.0).y, ItemView.pile_offset(3, 10.0).y, "top of the pile is higher")


func test_order_tools_use_priority() -> void:
	assert_true(ToolController.is_order_tool(ToolController.Tool.DIG))
	assert_true(ToolController.is_order_tool(ToolController.Tool.LADDER))
	assert_false(ToolController.is_order_tool(ToolController.Tool.STOCKPILE))
	assert_false(ToolController.is_order_tool(ToolController.Tool.SELECT))
