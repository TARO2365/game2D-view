extends GutTest

const FS := preload("res://tests/helpers/fs_util.gd")

var reg: TileRegistry
var g: WorldGrid


func before_all() -> void:
	reg = TileRegistry.load_default()


func before_each() -> void:
	g = FS.make_grid(reg)


func test_dig_changes_only_diggable_tiles_and_reports_rect() -> void:
	watch_signals(g)
	# Rows 8..11: 8-9 are air, 10-11 dirt.
	var r := g.apply_edit(Rect2i(5, 8, 3, 4), WorldGrid.Edit.DIG)
	assert_true(r.ok, str(r))
	assert_eq(r.data["changed"], 6)
	assert_eq(r.data["skipped"], 6)
	assert_eq(r.data["rect"], Rect2i(5, 10, 3, 2))
	assert_eq(g.get_tile(Vector2i(5, 10)), TileRegistry.AIR)
	assert_signal_emit_count(g, "tiles_changed", 1)
	assert_signal_emitted_with_parameters(g, "tiles_changed", [Rect2i(5, 10, 3, 2)])


func test_dig_rejects_bedrock_and_air() -> void:
	watch_signals(g)
	var before := g.world_hash()
	var r1 := g.apply_edit(Rect2i(0, 63, 10, 1), WorldGrid.Edit.DIG)
	assert_false(r1.ok)
	assert_eq(r1.code, &"nothing_to_change")
	var r2 := g.apply_edit(Rect2i(0, 0, 10, 5), WorldGrid.Edit.DIG)
	assert_false(r2.ok)
	assert_eq(g.world_hash(), before)
	assert_signal_not_emitted(g, "tiles_changed")


func test_build_only_into_air() -> void:
	var r := g.apply_edit(Rect2i(0, 9, 4, 2), WorldGrid.Edit.BUILD_WALL)
	assert_true(r.ok)
	assert_eq(r.data["changed"], 4)
	assert_eq(g.get_tile(Vector2i(0, 9)), TileRegistry.CONCRETE)
	assert_eq(g.get_tile(Vector2i(0, 10)), TileRegistry.DIRT)
	var r2 := g.apply_edit(Rect2i(0, 20, 4, 4), WorldGrid.Edit.BUILD_WALL)
	assert_false(r2.ok)


func test_out_of_bounds() -> void:
	var r := g.apply_edit(Rect2i(-20, -20, 5, 5), WorldGrid.Edit.DIG)
	assert_false(r.ok)
	assert_eq(r.code, &"out_of_bounds")
	var partial := g.apply_edit(Rect2i(-3, 20, 5, 1), WorldGrid.Edit.DIG)
	assert_true(partial.ok)
	assert_eq(partial.data["changed"], 2)


func test_modified_chunks_tracked() -> void:
	assert_true(g.modified_chunks().is_empty())
	g.apply_edit(Rect2i(40, 40, 1, 1), WorldGrid.Edit.DIG)
	assert_eq(g.modified_chunks(), [g.chunk_index(Vector2i(1, 1))] as Array[int])


func test_chunk_math() -> void:
	var big := WorldGrid.new(100, 70, reg)
	assert_eq(big.chunks_x(), 4)
	assert_eq(big.chunks_y(), 3)
	assert_eq(big.chunk_rect(Vector2i(3, 2)), Rect2i(96, 64, 4, 6))
	assert_eq(big.chunk_coords_of_index(big.chunk_index(Vector2i(2, 1))), Vector2i(2, 1))
	assert_eq(big.chunks_in_rect(Rect2i(30, 30, 4, 4)),
			[Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)] as Array[Vector2i])
	assert_eq(big.chunks_in_rect(Rect2i(-50, -50, 5, 5)).size(), 0)


func test_chunk_bytes_round_trip() -> void:
	g.apply_edit(Rect2i(33, 33, 5, 5), WorldGrid.Edit.DIG)
	var other := FS.make_grid(reg)
	var c := Vector2i(1, 1)
	assert_true(other.set_chunk_bytes(c, g.get_chunk_bytes(c)))
	assert_eq(other.world_hash(), g.world_hash())
	assert_false(other.set_chunk_bytes(c, PackedByteArray([1, 2, 3])), "wrong size rejected")
	assert_false(other.set_chunk_bytes(Vector2i(9, 9), g.get_chunk_bytes(c)), "bad coords rejected")


func test_hash_changes_with_edit() -> void:
	var before := g.world_hash()
	g.apply_edit(Rect2i(1, 20, 1, 1), WorldGrid.Edit.DIG)
	assert_ne(g.world_hash(), before)
