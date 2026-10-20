extends GutTest

const FS := preload("res://tests/helpers/fs_util.gd")
const CHUNK_PX := WorldGrid.CHUNK_SIZE * 64

var reg: TileRegistry
var g: WorldGrid
var view: WorldView


func before_all() -> void:
	reg = TileRegistry.load_default()


func before_each() -> void:
	g = FS.make_grid(reg, Vector2i(128, 128))  # 4x4 chunks
	view = WorldView.new()
	view.setup(g, 64)
	add_child_autofree(view)


func test_streams_only_chunks_near_view() -> void:
	view.update_visible(Rect2(0, 0, CHUNK_PX - 1, CHUNK_PX - 1))
	assert_eq(view.loaded_chunk_count(), 4, "chunk (0,0) + 1 margin")
	view.update_visible(Rect2(3 * CHUNK_PX, 3 * CHUNK_PX, CHUNK_PX - 1, CHUNK_PX - 1))
	assert_eq(view.loaded_chunk_count(), 4)
	assert_null(view.get_chunk_layer(Vector2i(0, 0)), "far chunk released")
	assert_not_null(view.get_chunk_layer(Vector2i(3, 3)))


func test_cells_match_grid() -> void:
	view.update_visible(Rect2(0, 0, 10, 10))
	var layer := view.get_chunk_layer(Vector2i(0, 0))
	assert_eq(layer.get_cell_source_id(Vector2i(0, 5)), -1, "air has no cell")
	assert_eq(layer.get_cell_atlas_coords(Vector2i(0, 12)), Vector2i(TileRegistry.DIRT, 0))


func test_edit_redraws_only_affected_loaded_chunk() -> void:
	view.update_visible(Rect2(0, 0, 10, 10))  # loads chunks (0..1, 0..1)
	view.redraw_count = 0
	g.apply_edit(Rect2i(3, 12, 2, 2), WorldGrid.Edit.DIG)
	assert_eq(view.redraw_count, 1)
	assert_eq(view.get_chunk_layer(Vector2i(0, 0)).get_cell_source_id(Vector2i(3, 12)), -1)
	g.apply_edit(Rect2i(100, 100, 2, 2), WorldGrid.Edit.DIG)  # chunk (3,3) not loaded
	assert_eq(view.redraw_count, 1, "unloaded chunks are not redrawn")
	view.update_visible(Rect2(3 * CHUNK_PX, 3 * CHUNK_PX, 10, 10))
	assert_eq(view.get_chunk_layer(Vector2i(3, 3)).get_cell_source_id(Vector2i(100 - 96, 100 - 96)), -1,
			"edit visible after streaming in")
