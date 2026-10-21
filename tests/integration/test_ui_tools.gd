extends GutTest
## M2 UI: Ladder / Stockpile / Clear stockpile / Priority tools, the 1-9
## priority selector, ladder and item rendering.

const FS := preload("res://tests/helpers/fs_util.gd")
const GAME := preload("res://scenes/game.tscn")

var root: String
var slots: WorldSlots
var session: WorldSession
var game: GameScreen


func before_each() -> void:
	root = FS.temp_root("ui_tools")
	slots = WorldSlots.new(TileRegistry.load_default(), root)
	session = slots.create_world("UI Tools", 5, &"small").data["session"]
	session.clock.set_speed(0)
	game = GAME.instantiate()
	game.setup(session, slots, load("res://data/config/scale_config.tres"))
	add_child_autofree(game)
	await wait_process_frames(2)


func after_each() -> void:
	FS.rm_rf(root)


## Open air column near the camera (centre of the world), above the surface.
func _air_rect() -> Rect2i:
	var x := session.grid.width / 2 + 6
	return Rect2i(x, session.grid.surface_y[x] - 3, 1, 3)


func _underground_rect() -> Rect2i:
	var x := 100
	return Rect2i(x, session.grid.surface_y[x] + 2, 4, 3)


func _floor_tile() -> Vector2i:
	var x := session.grid.width / 2 + 6
	return Vector2i(x, session.grid.surface_y[x] - 1)


func test_ladder_tool_places_ladder_orders() -> void:
	game.toolbar.get_tool_button(ToolController.Tool.LADDER).pressed.emit()
	assert_eq(game.tools.tool, ToolController.Tool.LADDER)
	var r := game.tools.apply_rect(_air_rect())
	assert_true(r.ok, str(r))
	for y in range(_air_rect().position.y, _air_rect().end.y):
		var p := Vector2i(_air_rect().position.x, y)
		assert_eq(session.designations.get_kind(p), DesignationMap.Kind.BUILD_LADDER)
		assert_false(session.grid.is_ladder(p), "order only (D-015)")


func test_priority_selector_used_for_new_orders() -> void:
	game.set_tool(ToolController.Tool.DIG)
	assert_true(game.toolbar.priority_box.visible, "selector shown for order tools")
	game.toolbar.get_priority_button(8).pressed.emit()
	assert_eq(game.tools.priority, 8)
	assert_true(game.tools.apply_rect(_underground_rect()).ok)
	assert_eq(session.designations.get_priority(_underground_rect().position), 8)
	game.set_tool(ToolController.Tool.LADDER)
	game.toolbar.get_priority_button(3).pressed.emit()
	assert_true(game.tools.apply_rect(_air_rect()).ok)
	assert_eq(session.designations.get_priority(_air_rect().position), 3)
	game.set_tool(ToolController.Tool.SELECT)
	assert_false(game.toolbar.priority_box.visible)


func test_priority_tool_changes_existing_orders() -> void:
	game.set_tool(ToolController.Tool.DIG)
	game.tools.apply_rect(_underground_rect())
	assert_eq(session.designations.get_priority(_underground_rect().position), DesignationMap.DEFAULT_PRIORITY)
	game.set_tool(ToolController.Tool.PRIORITY)
	assert_true(game.overlay.show_priorities, "numbers shown")
	assert_true(game.toolbar.priority_box.visible)
	game.set_priority(9)
	var r := game.tools.apply_rect(_underground_rect())
	assert_true(r.ok, str(r))
	assert_eq(r.data["changed"], 12)
	assert_eq(session.designations.get_priority(_underground_rect().end - Vector2i.ONE), 9)
	game.set_tool(ToolController.Tool.SELECT)
	assert_false(game.overlay.show_priorities)


func test_priority_tool_failure_is_toasted() -> void:
	game.set_tool(ToolController.Tool.PRIORITY)
	var r := game.tools.apply_rect(Rect2i(1, 1, 2, 2))
	assert_false(r.ok)
	assert_eq(game.toast.text, r.message)
	assert_false(game.set_priority(12).ok)
	assert_eq(game.tools.priority, DesignationMap.DEFAULT_PRIORITY)


func test_stockpile_and_clear_tools() -> void:
	var t := _floor_tile()
	game.set_tool(ToolController.Tool.STOCKPILE)
	var r := game.tools.apply_rect(Rect2i(t, Vector2i.ONE))
	assert_true(r.ok, str(r))
	assert_true(session.stockpiles.is_stockpile(t))
	game.set_tool(ToolController.Tool.CLEAR_STOCKPILE)
	assert_true(game.tools.apply_rect(Rect2i(t, Vector2i.ONE)).ok)
	assert_false(session.stockpiles.is_stockpile(t))
	assert_false(game.tools.apply_rect(Rect2i(t, Vector2i.ONE)).ok, "nothing left to clear")


func test_dev_instant_ladder_renders_as_cell() -> void:
	assert_true(game.tools.set_dev_instant(true).ok)
	game.set_tool(ToolController.Tool.LADDER)
	var r := game.tools.apply_rect(_air_rect())
	assert_true(r.ok, str(r))
	var p := _air_rect().position
	assert_true(session.grid.is_ladder(p))
	var c := p / WorldGrid.CHUNK_SIZE
	var layer := game.world_view.get_chunk_layer(c)
	assert_not_null(layer, "chunk near camera is loaded")
	var local := p - c * WorldGrid.CHUNK_SIZE
	assert_eq(layer.get_cell_source_id(local), PlaceholderTiles.STRUCTURE_SOURCE)
	assert_eq(layer.get_cell_atlas_coords(local), Vector2i(WorldGrid.Structure.LADDER, 0))


func test_ground_items_render_as_pile() -> void:
	var t := _floor_tile()
	session.inventory.spawn_ground(&"rock", 50.0, t)
	session.inventory.spawn_ground(&"dirt", 50.0, t)
	session.inventory.spawn_ground(&"iron_ore", 50.0, t + Vector2i.LEFT)
	await wait_process_frames(1)
	var piles := game.item_view.visible_piles()
	# Lead (M4a): the starting ration stack may also be visible, so check our two piles by tile.
	assert_true(piles.has(t + Vector2i.LEFT))
	assert_eq((piles[t] as Array).size(), 2)
	var far := Vector2i(2, session.grid.height - 3)
	session.inventory.spawn_ground(&"rock", 50.0, far)
	assert_false(game.item_view.visible_piles().has(far), "off-screen items are not drawn")


func test_overlay_tints_unreachable_orders() -> void:
	# A dig order deep inside solid ground: no NPC can get there.
	var x := session.grid.width / 2
	var deep := Rect2i(x, session.grid.height - 12, 2, 2)
	game.set_tool(ToolController.Tool.DIG)
	assert_true(game.tools.apply_rect(deep).ok)
	var tick := session.clock.tick_index
	for i in 400:
		tick += 1
		session.simulate_tick(tick)
		if session.jobs.is_unreachable(deep.position):
			break
	assert_true(session.jobs.is_unreachable(deep.position), "JobManager marked it")
	var px := float(game.scale_config.tile_size_px)
	game.overlay.set_visible_rect(Rect2(Vector2(deep.position) * px - Vector2(200, 200), Vector2(800, 600)))
	game.overlay.queue_redraw()
	await wait_process_frames(2)
	assert_gt(game.overlay.unreachable_drawn, 0, "drawn in red")
