extends GutTest
## Kitchens (M4a contract §5) with a fake Buildings provider.

const FB := preload("res://tests/helpers/fake_buildings.gd")
const R := Kitchens.RECIPE

var bld: RefCounted
var inv: Inventory
var kit: Kitchens


func before_each() -> void:
	bld = FB.new()
	inv = Inventory.new(StableIdAllocator.new())
	kit = Kitchens.new(bld, inv)


## Hauls kg of material to SITE(job) the way JobManager does.
func _deliver(material: StringName, kg: float, job: String) -> String:
	var id := inv.spawn_ground(material, kg, Vector2i(0, 9))
	var picked: String = inv.pick_up(id, "npc:99", kg).data["item_id"]
	inv.deliver_to_site("npc:99", job)
	return picked


func test_recipe_is_placeholder_contract() -> void:
	assert_eq(R["input"], &"mushroom")
	assert_eq(R["input_kg"], 2.0)
	assert_eq(R["output"], &"meal")
	assert_eq(R["output_kg"], 2.0)
	assert_eq(R["work_ticks"], 60)


func test_kitchens_follow_buildings_and_targets() -> void:
	var k: String = bld.place(&"kitchen", Vector2i(3, 9))
	var f: String = bld.place(&"farm_plot", Vector2i(6, 9))
	assert_eq(kit.kitchen_ids(), [k] as Array[String])
	assert_eq(kit.target_kg(k), 10.0, "default target")
	assert_eq(kit.target_kg(f), 0.0)
	assert_true(kit.needs_cooking(9.0, k))
	assert_false(kit.needs_cooking(10.0, k))
	assert_false(kit.needs_cooking(0.0, f), "not a kitchen")
	assert_false(kit.needs_cooking(NAN, k))
	watch_signals(kit)
	assert_true(kit.set_target_kg(k, 25.0).ok)
	assert_eq(kit.target_kg(k), 25.0)
	assert_true(kit.needs_cooking(24.0, k))
	assert_signal_emitted_with_parameters(kit, "kitchens_changed", [k])
	assert_true(kit.set_target_kg(k, 0.0).ok, "0 = never cook")
	assert_false(kit.needs_cooking(0.0, k))
	assert_eq(kit.set_target_kg(k, -1.0).code, &"invalid_kg")
	assert_eq(kit.set_target_kg(k, INF).code, &"invalid_kg")
	assert_eq(kit.set_target_kg(k, Kitchens.MAX_TARGET_KG + 1.0).code, &"invalid_kg")
	assert_eq(kit.set_target_kg(f, 5.0).code, &"not_kitchen")
	assert_eq(kit.target_kg(k), 0.0, "failed sets keep the old value")


func test_cook_consumes_input_and_spawns_output() -> void:
	var k: String = bld.place(&"kitchen", Vector2i(3, 9))
	var a := _deliver(&"mushroom", 1.5, "job:4")
	var b := _deliver(&"mushroom", 1.0, "job:4")
	var other := _deliver(&"rock", 3.0, "job:4")
	watch_signals(inv)
	var r := kit.cook(k, "job:4", Vector2i(4, 9))
	assert_true(r.ok, str(r))
	assert_almost_eq(float(r.data["consumed_kg"]), 2.0, 1e-9)
	var meal := inv.get_item(r.data["item_id"])
	assert_eq(meal.material, &"meal")
	assert_eq(meal.kg, 2.0)
	assert_eq(meal.holder, Inventory.Holder.GROUND)
	assert_eq(meal.tile, Vector2i(4, 9))
	assert_null(inv.get_item(a), "oldest stack fully used")
	assert_almost_eq(inv.get_item(b).kg, 0.5, 1e-9, "rest of the next stack stays at the site")
	assert_eq(inv.get_item(other).holder, Inventory.Holder.SITE, "other materials untouched")
	assert_almost_eq(inv.site_kg("job:4"), 3.5, 1e-9)
	assert_almost_eq(float(inv.consumed_kg_by_material()[&"mushroom"]), 2.0, 1e-9)
	assert_eq(float(inv.spawned_kg_by_material()[&"meal"]), 2.0)
	assert_signal_emitted(inv, "items_changed")
	assert_eq(inv.check_conservation(), [] as Array[String])
	assert_eq(inv.verify_indexes(), [] as Array[String])


func test_cook_fails_cleanly() -> void:
	var k: String = bld.place(&"kitchen", Vector2i(3, 9))
	var f: String = bld.place(&"farm_plot", Vector2i(6, 9))
	_deliver(&"mushroom", 1.9, "job:1")
	_deliver(&"meal", 5.0, "job:1")
	var before := inv.to_snapshot()
	var r := kit.cook(k, "job:1", Vector2i(4, 9))
	assert_eq(r.code, &"missing_input")
	assert_almost_eq(float(r.data["available_kg"]), 1.9, 1e-9)
	assert_eq(kit.cook(k, "job:9", Vector2i(4, 9)).code, &"missing_input", "empty site")
	assert_eq(kit.cook(k, "", Vector2i(4, 9)).code, &"invalid_job")
	assert_eq(kit.cook(f, "job:1", Vector2i(4, 9)).code, &"not_kitchen")
	assert_eq(kit.cook("bld:99", "job:1", Vector2i(4, 9)).code, &"not_kitchen")
	assert_eq(inv.to_snapshot(), before, "nothing changed")
	_deliver(&"mushroom", 0.1, "job:1")
	assert_true(kit.cook(k, "job:1", Vector2i(4, 9)).ok, "exactly 2.0 kg now")
	assert_eq(inv.site_kg("job:1"), 5.0, "only the meal is left")
	assert_eq(inv.check_conservation(), [] as Array[String])


func test_removed_or_lost_kitchen_drops_target() -> void:
	var k: String = bld.place(&"kitchen", Vector2i(3, 9))
	var k2: String = bld.place(&"kitchen", Vector2i(8, 9))
	kit.set_target_kg(k, 30.0)
	kit.set_target_kg(k2, 40.0)
	watch_signals(kit)
	bld.remove(k)
	bld.lose(k2)
	assert_eq(kit.kitchen_ids(), [] as Array[String])
	assert_eq(kit.target_kg(k), 0.0)
	assert_eq(kit.to_snapshot(), {"targets": []})
	assert_signal_emit_count(kit, "kitchens_changed", 2)


func test_snapshot_round_trip_and_junk() -> void:
	var k: String = bld.place(&"kitchen", Vector2i(3, 9))
	var k2: String = bld.place(&"kitchen", Vector2i(8, 9))
	var k3: String = bld.place(&"kitchen", Vector2i(12, 9))
	var f: String = bld.place(&"farm_plot", Vector2i(6, 9))
	kit.set_target_kg(k, 30.0)
	kit.set_target_kg(k3, 0.0)
	var snap := kit.to_snapshot()
	assert_eq(snap, {"targets": [{"building_id": k, "kg": 30.0}, {"building_id": k3, "kg": 0.0}]},
			"default targets are not saved")
	var bytes := var_to_bytes(snap)
	var kit2 := Kitchens.new(bld, inv)
	assert_eq(kit2.load_snapshot(bytes_to_var(bytes)), 0)
	assert_eq(var_to_bytes(kit2.to_snapshot()), bytes)
	assert_eq(kit2.target_kg(k2), 10.0)
	var junk := {"targets": [
		{"building_id": k2, "kg": 12},
		{"building_id": k2, "kg": 13.0},       # duplicate
		{"building_id": f, "kg": 5.0},         # not a kitchen
		{"building_id": "bld:99", "kg": 5.0},
		{"building_id": k, "kg": -1.0},
		{"building_id": k, "kg": NAN},
		{"building_id": k, "kg": 1.0e9},
		{"building_id": k, "kg": "5"},
		{"kg": 5.0},
		"x",
	]}
	assert_eq(kit2.load_snapshot(junk), 9)
	assert_eq(kit2.target_kg(k2), 12.0)
	assert_eq(kit2.target_kg(k), 10.0)
	assert_eq(kit2.load_snapshot({"targets": 3}), 0)
	assert_eq(kit2.target_kg(k2), 10.0)
