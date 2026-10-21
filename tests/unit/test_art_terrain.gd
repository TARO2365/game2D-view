extends GutTest
## Smooth (ONI-style) terrain renderer data path (D-027 step 2).

const FS := preload("res://tests/helpers/fs_util.gd")

var reg: TileRegistry
var g: WorldGrid
var view: WorldView


func before_all() -> void:
	reg = TileRegistry.load_default()


func before_each() -> void:
	g = FS.make_grid(reg, Vector2i(128, 128))
	view = WorldView.new()
	view.setup(g, 64)
	add_child_autofree(view)


func test_chunk_data_layout_and_border() -> void:
	var n := TerrainRenderer.data_size()
	assert_eq(n, WorldGrid.CHUNK_SIZE + 2)
	var img := TerrainRenderer.chunk_image(g, Vector2i(1, 0))
	assert_eq(img.get_size(), Vector2i(n, n))
	# Texel (1,1) is world cell (32, 0); texel (0, y) is the border column 31.
	for y in [5, 20]:
		var wy: int = y - 1
		assert_eq(img.get_pixel(1, y).r8, g.tiles[wy * g.width + 32], "cell (32,%d)" % wy)
		assert_eq(img.get_pixel(0, y).r8, g.tiles[wy * g.width + 31], "left border")


func test_underground_flag_and_structures() -> void:
	var x := 10
	var sy: int = g.surface_y[x]
	assert_true(g.apply_edit(Rect2i(x, sy + 2, 1, 1), WorldGrid.Edit.DIG).ok)
	assert_true(g.apply_structure(Vector2i(x, sy + 2), WorldGrid.Structure.LADDER).ok)
	var img := TerrainRenderer.chunk_image(g, Vector2i(0, 0))
	var px := img.get_pixel(x + 1, sy + 2 + 1)
	assert_eq(px.r8, TileRegistry.AIR)
	assert_eq(px.g8, WorldGrid.Structure.LADDER)
	assert_eq(px.b8, 255, "dug air below the surface is underground")
	if sy > 0:
		assert_eq(img.get_pixel(x + 1, 1).b8, 0, "open sky is not underground")


func test_smooth_view_hides_tilemaps_and_keeps_api() -> void:
	view.update_visible(Rect2(0, 0, 10, 10))
	var layer := view.get_chunk_layer(Vector2i(0, 0))
	assert_not_null(layer, "cell data API intact")
	assert_eq(layer.enabled, not WorldView.smooth_terrain)
	if WorldView.smooth_terrain:
		assert_not_null(view.get_terrain_image(Vector2i(0, 0)))


func test_edit_updates_only_touched_chunk_data() -> void:
	if not WorldView.smooth_terrain:
		pass_test("smooth renderer off")
		return
	view.update_visible(Rect2(0, 0, 10, 10))  # chunks (0..1, 0..1)
	view.terrain_updates = 0
	var y: int = g.surface_y[5] + 3
	g.apply_edit(Rect2i(5, y, 1, 1), WorldGrid.Edit.DIG)
	assert_eq(view.terrain_updates, 1, "interior edit -> one chunk")
	assert_eq(view.get_terrain_image(Vector2i(0, 0)).get_pixel(6, y + 1).r8, TileRegistry.AIR)
	view.terrain_updates = 0
	g.apply_edit(Rect2i(31, y, 1, 1), WorldGrid.Edit.DIG)
	assert_eq(view.terrain_updates, 2, "edit on the chunk border also refreshes the neighbour")
	assert_eq(view.get_terrain_image(Vector2i(1, 0)).get_pixel(0, y + 1).r8, TileRegistry.AIR, "neighbour border cell")
