extends GutTest


func test_wall_recipe() -> void:
	var r := ConstructionDefs.recipe(ConstructionDefs.KIND_BUILD_WALL)
	assert_eq(r["materials"], [&"rock"] as Array[StringName])
	assert_eq(r["kg"], 50.0)
	assert_eq(r["work_ticks"], 30)
	assert_eq(typeof(r["kg"]), TYPE_FLOAT)
	assert_eq(typeof(r["work_ticks"]), TYPE_INT)


func test_ladder_recipe() -> void:
	var r := ConstructionDefs.recipe(ConstructionDefs.KIND_BUILD_LADDER)
	assert_eq(r["materials"], [&"rock", &"dirt"] as Array[StringName])
	assert_eq(r["kg"], 25.0)
	assert_eq(r["work_ticks"], 20)


func test_unknown_kinds_empty() -> void:
	assert_eq(ConstructionDefs.recipe(0), {})
	assert_eq(ConstructionDefs.recipe(1), {}, "DIG needs no materials")
	assert_eq(ConstructionDefs.recipe(99), {})
	assert_eq(ConstructionDefs.recipe(-1), {})


func test_recipe_is_a_fresh_copy() -> void:
	var r := ConstructionDefs.recipe(ConstructionDefs.KIND_BUILD_WALL)
	(r["materials"] as Array).append(&"gold_ore")
	r["kg"] = 1.0
	var again := ConstructionDefs.recipe(ConstructionDefs.KIND_BUILD_WALL)
	assert_eq(again["materials"].size(), 1)
	assert_eq(again["kg"], 50.0)


func test_accepts() -> void:
	assert_true(ConstructionDefs.accepts(ConstructionDefs.KIND_BUILD_WALL, &"rock"))
	assert_false(ConstructionDefs.accepts(ConstructionDefs.KIND_BUILD_WALL, &"dirt"))
	assert_true(ConstructionDefs.accepts(ConstructionDefs.KIND_BUILD_LADDER, &"dirt"))
	assert_false(ConstructionDefs.accepts(1, &"dirt"))


func test_material_keys_exist_in_tile_registry() -> void:
	var keys := {}
	for d in TileRegistry.load_default().all_defs():
		keys[d.key] = true
	for kind in [ConstructionDefs.KIND_BUILD_WALL, ConstructionDefs.KIND_BUILD_LADDER]:
		for m: StringName in ConstructionDefs.recipe(kind)["materials"]:
			assert_true(keys.has(m), "%s is a TileDef key" % m)


func test_kind_constants_match_designation_map() -> void:
	assert_eq(ConstructionDefs.KIND_BUILD_WALL, DesignationMap.Kind.BUILD_WALL)
	# BUILD_LADDER is added to DesignationMap.Kind by the Lead (contract §6).
	var kinds: Dictionary = DesignationMap.Kind  # untyped access: key may not exist yet
	if kinds.has("BUILD_LADDER"):
		assert_eq(ConstructionDefs.KIND_BUILD_LADDER, kinds["BUILD_LADDER"])
	else:
		pass_test("DesignationMap.Kind.BUILD_LADDER not added yet; contract value is 3")
