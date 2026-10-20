extends GutTest
## ArtLibrary: production PNGs are found by the ASSET_SPEC names and missing
## files fall back to procedural art without errors (D-020).

const TEST_DIR := "user://art_test/"

var _saved_base := ""


func before_each() -> void:
	_saved_base = ArtLibrary.base_dir
	ArtLibrary.base_dir = TEST_DIR
	ArtLibrary.clear_cache()
	DirAccess.make_dir_recursive_absolute(TEST_DIR + "terrain")
	DirAccess.make_dir_recursive_absolute(TEST_DIR + "characters")
	DirAccess.make_dir_recursive_absolute(TEST_DIR + "structures")


func after_each() -> void:
	for rel in ["terrain/terrain_dirt.png", "characters/npc_miner_walk.png", "structures/ladder.png"]:
		if FileAccess.file_exists(TEST_DIR + rel):
			DirAccess.remove_absolute(TEST_DIR + rel)
	ArtLibrary.base_dir = _saved_base
	ArtLibrary.clear_cache()


func _solid(w: int, h: int, c: Color) -> Image:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(c)
	return img


func test_spec_file_names() -> void:
	assert_eq(ArtLibrary.terrain_path(&"iron_ore"), "terrain/terrain_iron_ore.png")
	assert_eq(ArtLibrary.npc_sheet_path(&"miner", &"walk"), "characters/npc_miner_walk.png")
	assert_eq(ArtLibrary.item_path(&"gold_ore"), "items/item_gold_ore.png")
	assert_eq(ArtLibrary.structure_path(&"ladder"), "structures/ladder.png")
	assert_eq(ArtLibrary.building_path(&"door"), "buildings/building_door.png")
	assert_eq(ArtLibrary.ui_icon_path(&"dig"), "ui/icon_dig.png")
	assert_eq(ArtLibrary.background_path(&"backwall_dug"), "backgrounds/backwall_dug.png")


func test_missing_files_return_null() -> void:
	assert_null(ArtLibrary.texture("terrain/terrain_nope.png"))
	assert_null(ArtLibrary.terrain_strip(&"dirt", 64))
	assert_null(ArtLibrary.npc_sheet(&"miner", &"walk"))
	assert_null(ArtLibrary.item_texture(&"rock"))


func test_production_terrain_strip_is_used_and_scaled() -> void:
	var strip := Image.create(128 * 4, 128, false, Image.FORMAT_RGBA8)
	for v in 4:
		strip.fill_rect(Rect2i(v * 128, 0, 128, 128), Color(0.1 * (v + 1), 0.2, 0.3))
	strip.save_png(TEST_DIR + "terrain/terrain_dirt.png")
	var out := ArtLibrary.terrain_strip(&"dirt", 64)
	assert_not_null(out)
	assert_eq(out.get_size(), Vector2i(256, 64), "4 variants rescaled to 64 px")
	assert_almost_eq(out.get_pixel(64 * 2 + 32, 32).r, 0.3, 0.02, "variant order kept")
	# The tileset picks it up instead of the procedural tile.
	var reg := TileRegistry.load_default()
	var tile := PlaceholderTiles.terrain_tile_image(reg.get_def(TileRegistry.DIRT), 1, 64)
	assert_almost_eq(tile.get_pixel(10, 10).r, 0.2, 0.02)


func test_npc_sheet_frames() -> void:
	_solid(96 * 6, 192, Color.RED).save_png(TEST_DIR + "characters/npc_miner_walk.png")
	var sheet := ArtLibrary.npc_sheet(&"miner", &"walk")
	assert_not_null(sheet)
	assert_eq(ArtLibrary.frame_count(sheet), 6)
	assert_eq(ArtLibrary.frame_region(7, 6), Rect2(96, 0, 96, 192), "frames wrap")


func test_undersized_sheet_is_rejected() -> void:
	_solid(50, 50, Color.RED).save_png(TEST_DIR + "characters/npc_miner_walk.png")
	assert_null(ArtLibrary.npc_sheet(&"miner", &"walk"))


func test_production_ladder_used() -> void:
	_solid(64, 64, Color(0, 1, 0)).save_png(TEST_DIR + "structures/ladder.png")
	var img := ArtLibrary.tile_image(ArtLibrary.structure_path(&"ladder"), 32)
	assert_eq(img.get_size(), Vector2i(32, 32))
	assert_almost_eq(img.get_pixel(5, 5).g, 1.0, 0.01)


func test_cache_remembers_misses_until_cleared() -> void:
	assert_null(ArtLibrary.terrain_strip(&"dirt", 64))
	var strip := _solid(64 * 4, 64, Color.BLUE)
	strip.save_png(TEST_DIR + "terrain/terrain_dirt.png")
	assert_null(ArtLibrary.terrain_strip(&"dirt", 64), "cached miss")
	ArtLibrary.clear_cache()
	assert_not_null(ArtLibrary.terrain_strip(&"dirt", 64))
