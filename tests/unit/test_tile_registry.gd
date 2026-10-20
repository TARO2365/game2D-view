extends GutTest

var reg: TileRegistry


func before_all() -> void:
	reg = TileRegistry.load_default()


func test_ids_match_constants() -> void:
	var expected := {
		TileRegistry.AIR: &"air", TileRegistry.DIRT: &"dirt", TileRegistry.ROCK: &"rock",
		TileRegistry.IRON_ORE: &"iron_ore", TileRegistry.GOLD_ORE: &"gold_ore",
		TileRegistry.CRYSTAL: &"crystal", TileRegistry.BEDROCK: &"bedrock", TileRegistry.CONCRETE: &"concrete",
	}
	for id in expected:
		var d := reg.get_def(id)
		assert_not_null(d, "def for id %d" % id)
		if d:
			assert_eq(d.key, expected[id])
	assert_eq(reg.all_defs().size(), expected.size(), "no extra/duplicate defs")
	assert_eq(reg.max_id(), TileRegistry.CONCRETE)


func test_rules() -> void:
	assert_false(reg.is_solid(TileRegistry.AIR))
	assert_false(reg.is_diggable(TileRegistry.AIR))
	assert_true(reg.is_diggable(TileRegistry.DIRT))
	assert_true(reg.is_diggable(TileRegistry.GOLD_ORE))
	assert_false(reg.is_diggable(TileRegistry.BEDROCK))
	assert_false(reg.is_diggable(TileRegistry.CONCRETE))
	assert_false(reg.is_diggable(250), "unknown id is not diggable")
