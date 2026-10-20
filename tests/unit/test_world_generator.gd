extends GutTest

const SIZE := Vector2i(160, 96)
## Golden value: terrain hash for seed 12345, Medium, GEN_VERSION 1.
## If this changes without a GEN_VERSION bump, existing saves break.
const GOLDEN_MEDIUM_12345 := "84324cbea13c57196b5bafcd3edd62d17709d12b95563d1266deb0bb03620a8d"

var reg: TileRegistry


func before_all() -> void:
	reg = TileRegistry.load_default()


func test_version_and_presets() -> void:
	assert_eq(WorldGenerator.GEN_VERSION, 1)
	assert_eq(WorldGenerator.PRESETS[&"medium"], Vector2i(512, 256))
	assert_eq(WorldGenerator.DEFAULT_PRESET, &"medium")


func test_same_seed_same_world() -> void:
	var a := WorldGenerator.generate(42, SIZE, reg)
	var b := WorldGenerator.generate(42, SIZE, reg)
	assert_eq(a.world_hash(), b.world_hash())
	assert_eq(a.surface_y, b.surface_y)


func test_different_seed_different_world() -> void:
	var a := WorldGenerator.generate(42, SIZE, reg)
	var b := WorldGenerator.generate(43, SIZE, reg)
	assert_ne(a.world_hash(), b.world_hash())


func test_layout_rules() -> void:
	var g := WorldGenerator.generate(7, SIZE, reg)
	assert_eq(g.get_size(), SIZE)
	var bad := 0
	for x in SIZE.x:
		var s := g.surface_y[x]
		if s < 4:
			bad += 1
		for y in s:
			if g.get_tile(Vector2i(x, y)) != TileRegistry.AIR:
				bad += 1
		if not reg.is_solid(g.get_tile(Vector2i(x, s))):
			bad += 1
		for y in range(SIZE.y - WorldGenerator.BEDROCK_ROWS, SIZE.y):
			if g.get_tile(Vector2i(x, y)) != TileRegistry.BEDROCK:
				bad += 1
	for x in [0, SIZE.x - 1]:
		for y in range(g.surface_y[x], SIZE.y):
			if g.get_tile(Vector2i(x, y)) != TileRegistry.BEDROCK:
				bad += 1
	assert_eq(bad, 0, "violations of sky/surface/bedrock rules")
	assert_true(g.modified_chunks().is_empty(), "fresh world has no modified chunks")


func test_medium_world_has_all_ores_and_golden_hash() -> void:
	var g := WorldGenerator.generate(12345, WorldGenerator.PRESETS[&"medium"], reg)
	var counts := {}
	for v in g.tiles:
		counts[v] = counts.get(v, 0) + 1
	for id in [TileRegistry.DIRT, TileRegistry.ROCK, TileRegistry.IRON_ORE, TileRegistry.GOLD_ORE, TileRegistry.CRYSTAL]:
		assert_gt(counts.get(id, 0), 0, "tile %d present" % id)
	gut.p("medium seed 12345 terrain hash = %s" % g.terrain_hash())
	assert_eq(g.terrain_hash(), GOLDEN_MEDIUM_12345)
	assert_eq(g.structures.size(), g.tiles.size(), "structure layer allocated")
	assert_eq(g.structures.count(WorldGrid.Structure.NONE), g.structures.size(), "no structures generated")


func test_seed_from_text() -> void:
	assert_eq(WorldGenerator.seed_from_text("123"), 123)
	assert_eq(WorldGenerator.seed_from_text(" -55 "), 55)
	var h := WorldGenerator.seed_from_text("bunker")
	assert_eq(h, WorldGenerator.seed_from_text("bunker"), "text seed is stable")
	assert_ne(h, WorldGenerator.seed_from_text("bunker2"))
	var r := WorldGenerator.seed_from_text("")
	assert_between(r, 0, 0x7fffffff)
