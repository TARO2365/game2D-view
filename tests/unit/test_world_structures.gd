extends GutTest
## Structure layer (ladders) and drop_kg (M2 contract §2).

const FS := preload("res://tests/helpers/fs_util.gd")

var reg: TileRegistry
var g: WorldGrid


func before_all() -> void:
	reg = TileRegistry.load_default()


func before_each() -> void:
	# Rows < 10 air, 10..62 dirt, row 63 bedrock.
	g = FS.make_grid(reg)


func test_layer_allocated_and_empty() -> void:
	assert_eq(g.structures.size(), g.tiles.size())
	assert_eq(g.get_structure(Vector2i(3, 3)), WorldGrid.Structure.NONE)
	assert_false(g.is_ladder(Vector2i(3, 3)))


func test_place_ladder_in_air() -> void:
	watch_signals(g)
	var p := Vector2i(40, 9)
	assert_true(g.can_place_structure(p, WorldGrid.Structure.LADDER))
	var r := g.apply_structure(p, WorldGrid.Structure.LADDER)
	assert_true(r.ok, str(r))
	assert_eq(g.get_structure(p), WorldGrid.Structure.LADDER)
	assert_true(g.is_ladder(p))
	assert_signal_emit_count(g, "tiles_changed", 1)
	assert_signal_emitted_with_parameters(g, "tiles_changed", [Rect2i(p, Vector2i.ONE)])
	assert_eq(g.modified_chunks(), [g.chunk_index(Vector2i(1, 0))] as Array[int])


func test_place_rejections() -> void:
	watch_signals(g)
	var solid := Vector2i(5, 20)
	assert_false(g.can_place_structure(solid, WorldGrid.Structure.LADDER))
	assert_eq(g.apply_structure(solid, WorldGrid.Structure.LADDER).code, &"blocked")
	var oob := Vector2i(-1, 5)
	assert_false(g.can_place_structure(oob, WorldGrid.Structure.LADDER))
	assert_eq(g.apply_structure(oob, WorldGrid.Structure.LADDER).code, &"out_of_bounds")
	assert_false(g.can_place_structure(Vector2i(2, 2), WorldGrid.Structure.NONE))
	assert_false(g.apply_structure(Vector2i(2, 2), WorldGrid.Structure.NONE).ok)
	assert_signal_not_emitted(g, "tiles_changed")
	assert_true(g.modified_chunks().is_empty())
	var p := Vector2i(2, 2)
	assert_true(g.apply_structure(p, WorldGrid.Structure.LADDER).ok)
	assert_false(g.can_place_structure(p, WorldGrid.Structure.LADDER))
	assert_eq(g.apply_structure(p, WorldGrid.Structure.LADDER).code, &"occupied")


func test_remove_structure() -> void:
	var p := Vector2i(7, 5)
	g.apply_structure(p, WorldGrid.Structure.LADDER)
	watch_signals(g)
	var r := g.remove_structure(p)
	assert_true(r.ok, str(r))
	assert_false(g.is_ladder(p))
	assert_signal_emitted_with_parameters(g, "tiles_changed", [Rect2i(p, Vector2i.ONE)])
	assert_false(g.remove_structure(p).ok, "nothing left to remove")
	assert_eq(g.remove_structure(Vector2i(99, 99)).code, &"out_of_bounds")


func test_build_wall_skips_ladder_tiles() -> void:
	var ladder := Vector2i(1, 9)
	g.apply_structure(ladder, WorldGrid.Structure.LADDER)
	var r := g.apply_edit(Rect2i(0, 9, 3, 1), WorldGrid.Edit.BUILD_WALL)
	assert_true(r.ok)
	assert_eq(r.data["changed"], 2)
	assert_eq(g.get_tile(ladder), TileRegistry.AIR)
	assert_true(g.is_ladder(ladder))
	assert_eq(g.get_tile(Vector2i(0, 9)), TileRegistry.CONCRETE)
	var only := g.apply_edit(Rect2i(ladder, Vector2i.ONE), WorldGrid.Edit.BUILD_WALL)
	assert_false(only.ok)
	assert_eq(only.code, &"nothing_to_change")


func test_passable_and_solid() -> void:
	var ladder := Vector2i(4, 4)
	g.apply_structure(ladder, WorldGrid.Structure.LADDER)
	assert_true(g.is_passable(Vector2i(4, 3)))
	assert_true(g.is_passable(ladder), "ladders are passable")
	assert_false(g.is_solid_at(ladder))
	assert_false(g.is_passable(Vector2i(4, 10)))
	assert_true(g.is_solid_at(Vector2i(4, 10)))
	for oob in [Vector2i(-1, 0), Vector2i(0, -1), Vector2i(64, 5), Vector2i(5, 64)]:
		assert_false(g.is_passable(oob), "out of bounds not passable %s" % oob)
		assert_true(g.is_solid_at(oob), "out of bounds is solid %s" % oob)
		assert_false(g.is_ladder(oob))


func test_chunk_bytes_round_trip_with_ladder() -> void:
	var c := Vector2i(1, 0)
	g.apply_edit(Rect2i(33, 10, 2, 2), WorldGrid.Edit.DIG)
	g.apply_structure(Vector2i(40, 5), WorldGrid.Structure.LADDER)
	var bytes := g.get_chunk_bytes(c)
	assert_eq(bytes.size(), 2 * g.chunk_rect(c).get_area())
	var other := FS.make_grid(reg)
	assert_true(other.set_chunk_bytes(c, bytes))
	assert_true(other.is_ladder(Vector2i(40, 5)))
	assert_eq(other.world_hash(), g.world_hash())
	assert_eq(other.terrain_hash(), g.terrain_hash())
	assert_false(other.set_chunk_bytes(c, bytes.slice(0, bytes.size() - 1)), "odd size rejected")
	assert_false(other.set_chunk_bytes(c, bytes + PackedByteArray([0])), "oversize rejected")


func test_legacy_v1_chunk_bytes_clear_structures() -> void:
	var c := Vector2i(0, 0)
	var area := g.chunk_rect(c).get_area()
	var source := FS.make_grid(reg)
	source.apply_edit(Rect2i(3, 10, 1, 1), WorldGrid.Edit.DIG)
	var v1 := source.get_chunk_bytes(c).slice(0, area)
	g.apply_structure(Vector2i(2, 2), WorldGrid.Structure.LADDER)
	assert_true(g.set_chunk_bytes(c, v1))
	assert_false(g.is_ladder(Vector2i(2, 2)), "v1 chunk clears structures")
	assert_eq(g.get_tile(Vector2i(3, 10)), TileRegistry.AIR)
	assert_eq(g.world_hash(), source.world_hash())


func test_hashes() -> void:
	var terrain := g.terrain_hash()
	var world := g.world_hash()
	assert_ne(world, terrain, "world hash covers the structure layer too")
	g.apply_structure(Vector2i(6, 6), WorldGrid.Structure.LADDER)
	assert_eq(g.terrain_hash(), terrain, "ladders are not terrain")
	assert_ne(g.world_hash(), world)
	g.remove_structure(Vector2i(6, 6))
	assert_eq(g.world_hash(), world)


func test_drop_kg() -> void:
	var expected := {
		TileRegistry.AIR: 0.0, TileRegistry.DIRT: 50.0, TileRegistry.ROCK: 50.0,
		TileRegistry.IRON_ORE: 50.0, TileRegistry.GOLD_ORE: 50.0, TileRegistry.CRYSTAL: 50.0,
		TileRegistry.BEDROCK: 0.0, TileRegistry.CONCRETE: 0.0,
	}
	for id in expected:
		assert_almost_eq(reg.get_def(id).drop_kg, expected[id], 0.0001, "drop_kg of tile %d" % id)
