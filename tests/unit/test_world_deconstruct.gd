extends GutTest
## WorldGrid M3 additions: Edit.DECONSTRUCT_WALL, building query hook, notify_changed.

const FS := preload("res://tests/helpers/fs_util.gd")

var reg: TileRegistry
var g: WorldGrid


func before_all() -> void:
	reg = TileRegistry.load_default()


func before_each() -> void:
	g = FS.make_grid(reg)


func test_edit_enum_values_are_stable() -> void:
	assert_eq(WorldGrid.Edit.DIG, 0)
	assert_eq(WorldGrid.Edit.BUILD_WALL, 1)
	assert_eq(WorldGrid.Edit.DECONSTRUCT_WALL, 2)


func test_deconstruct_wall_only_on_concrete() -> void:
	g.apply_edit(Rect2i(0, 9, 3, 1), WorldGrid.Edit.BUILD_WALL)
	var chunks_before := g.modified_chunks()
	watch_signals(g)
	# Rect covers concrete (0..2, 9), air (3, 9) and dirt (0..3, 10).
	var r := g.apply_edit(Rect2i(0, 9, 4, 2), WorldGrid.Edit.DECONSTRUCT_WALL)
	assert_true(r.ok, str(r))
	assert_eq(r.data["changed"], 3)
	assert_eq(r.data["skipped"], 5)
	assert_eq(r.data["rect"], Rect2i(0, 9, 3, 1))
	for x in 3:
		assert_eq(g.get_tile(Vector2i(x, 9)), TileRegistry.AIR)
	assert_eq(g.get_tile(Vector2i(0, 10)), TileRegistry.DIRT, "natural terrain is dug, not deconstructed")
	assert_signal_emit_count(g, "tiles_changed", 1)
	assert_signal_emitted_with_parameters(g, "tiles_changed", [Rect2i(0, 9, 3, 1)])
	assert_eq(g.modified_chunks(), chunks_before)


func test_deconstruct_nothing() -> void:
	watch_signals(g)
	var before := g.world_hash()
	var r := g.apply_edit(Rect2i(0, 5, 5, 10), WorldGrid.Edit.DECONSTRUCT_WALL)
	assert_false(r.ok)
	assert_eq(r.code, &"nothing_to_change")
	assert_eq(g.apply_edit(Rect2i(-9, -9, 2, 2), WorldGrid.Edit.DECONSTRUCT_WALL).code, &"out_of_bounds")
	assert_eq(g.world_hash(), before)
	assert_signal_not_emitted(g, "tiles_changed")


func test_concrete_cannot_be_dug() -> void:
	g.apply_edit(Rect2i(4, 9, 1, 1), WorldGrid.Edit.BUILD_WALL)
	assert_false(g.apply_edit(Rect2i(4, 9, 1, 1), WorldGrid.Edit.DIG).ok)
	assert_true(g.can_deconstruct(TileRegistry.CONCRETE))
	assert_false(g.can_deconstruct(TileRegistry.DIRT))
	assert_false(g.can_deconstruct(TileRegistry.AIR))


func test_building_query_hook() -> void:
	assert_false(g.has_building(Vector2i(2, 2)), "no query set")
	var occupied := {Vector2i(2, 9): true}
	g.set_building_query(func(p: Vector2i) -> bool: return occupied.has(p))
	assert_true(g.has_building(Vector2i(2, 9)))
	assert_false(g.can_place_structure(Vector2i(2, 9), WorldGrid.Structure.LADDER))
	assert_eq(g.apply_structure(Vector2i(2, 9), WorldGrid.Structure.LADDER).code, &"occupied")
	var r := g.apply_edit(Rect2i(1, 9, 3, 1), WorldGrid.Edit.BUILD_WALL)
	assert_eq(r.data["changed"], 2)
	assert_eq(g.get_tile(Vector2i(2, 9)), TileRegistry.AIR)
	g.set_building_query(Callable())
	assert_false(g.has_building(Vector2i(2, 9)))


func test_notify_changed() -> void:
	watch_signals(g)
	var before := g.modified_chunks()
	g.notify_changed(Rect2i(62, 5, 5, 2))
	assert_signal_emitted_with_parameters(g, "tiles_changed", [Rect2i(62, 5, 2, 2)])
	g.notify_changed(Rect2i(-10, -10, 2, 2))
	assert_signal_emit_count(g, "tiles_changed", 1, "outside the world: nothing")
	assert_eq(g.modified_chunks(), before)
