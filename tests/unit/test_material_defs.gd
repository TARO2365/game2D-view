extends GutTest
## MaterialDefs + data/defs/materials.tres (M4a contract §4).

var mats: MaterialDefs


func before_all() -> void:
	mats = MaterialDefs.load_default()


func test_loads() -> void:
	assert_not_null(mats)
	assert_eq(mats.all_keys(), [&"dirt", &"rock", &"iron_ore", &"gold_ore", &"crystal",
			&"mushroom", &"meal", &"ration"] as Array[StringName])


func test_every_tile_drop_material_has_an_entry() -> void:
	var reg := TileRegistry.load_default()
	var n := 0
	for t in reg.all_defs():
		if t.drop_kg > 0.0:
			n += 1
			assert_true(mats.has(t.key), "material entry for %s" % t.key)
			var d := mats.def(t.key)
			assert_true(d["category"] in [&"soil", &"ore"], "%s category" % t.key)
			assert_eq(d["nutrition_per_kg"], 0.0)
			assert_eq(d["color"], t.placeholder_color, "%s uses the tile colour" % t.key)
	assert_gt(n, 4)


func test_foods() -> void:
	assert_eq(mats.foods(), [&"mushroom", &"meal", &"ration"] as Array[StringName])
	assert_eq(mats.def(&"mushroom")["nutrition_per_kg"], 25.0)
	assert_eq(mats.def(&"meal")["nutrition_per_kg"], 60.0)
	assert_eq(mats.def(&"ration")["nutrition_per_kg"], 50.0)
	assert_true(mats.is_food(&"meal"))
	assert_false(mats.is_food(&"rock"))
	assert_eq(mats.nutrition_per_kg(&"ration"), 50.0)
	assert_eq(mats.nutrition_per_kg(&"nope"), 0.0)


func test_def_shape() -> void:
	var d := mats.def(&"meal")
	assert_eq(d["key"], &"meal")
	assert_eq(d["display_name"], "Meal")
	assert_eq(d["category"], &"food")
	assert_eq(typeof(d["color"]), TYPE_COLOR)
	assert_eq(mats.def(&"unknown"), {})
	assert_eq(mats.def(&""), {})
	assert_false(mats.has(&"air"), "air is not an item material")
	for k in mats.all_keys():
		assert_false(String(mats.def(k)["display_name"]).is_empty(), "%s has a name" % k)


func test_crate_filters_accept_any_material_key() -> void:
	var FB := preload("res://tests/helpers/fake_buildings.gd")
	var bld: RefCounted = FB.new()
	var inv := Inventory.new(StableIdAllocator.new())
	var cs := CrateStorage.new(bld, inv, mats)
	var c: String = bld.place(&"crate", Vector2i(3, 9))
	assert_true(cs.set_filter(c, [&"meal", &"ration", &"mushroom", &"iron_ore"] as Array[StringName]).ok)
	assert_true(cs.accepts(c, &"meal"))
	assert_false(cs.accepts(c, &"dirt"))
	assert_eq(cs.find_crate(&"ration", 20.0, Vector2i.ZERO), c)
	assert_eq(cs.set_filter(c, [&"plutonium"] as Array[StringName]).code, &"unknown_material")
	assert_eq(cs.get_filter(c), [&"iron_ore", &"meal", &"mushroom", &"ration"] as Array[StringName])
	var dropped := cs.load_snapshot({"filters": [{"building_id": c, "materials": ["meal", "plutonium"]}]})
	assert_eq(dropped, 1, "unknown material dropped on load")
	assert_eq(cs.get_filter(c), [&"meal"] as Array[StringName])
	# Without MaterialDefs (M3 behaviour) any non-empty key is accepted.
	var cs2 := CrateStorage.new(bld, inv)
	assert_true(cs2.set_filter(c, [&"plutonium"] as Array[StringName]).ok)
