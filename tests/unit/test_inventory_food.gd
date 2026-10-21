extends GutTest
## M4a food in Inventory: consume_item (eating), consume_from_site (cooking
## input), and a random walk over every item operation incl. crates, eating,
## cooking and harvesting with conservation + index checks at every step.

const FB := preload("res://tests/helpers/fake_buildings.gd")

var ids: StableIdAllocator
var inv: Inventory


func before_each() -> void:
	ids = StableIdAllocator.new()
	inv = Inventory.new(ids)


func _carry(material: StringName, kg: float, npc: String) -> String:
	var id := inv.spawn_ground(material, kg, Vector2i(0, 9))
	return inv.pick_up(id, npc, kg).data["item_id"]


func _assert_ok() -> void:
	assert_eq(inv.check_conservation(), [] as Array[String], "conservation")
	assert_eq(inv.verify_indexes(), [] as Array[String], "indexes")


func test_consume_part_of_carried_item() -> void:
	var m := _carry(&"meal", 2.0, "npc:1")
	watch_signals(inv)
	var r := inv.consume_item(m, 0.5)
	assert_true(r.ok, str(r))
	assert_eq(r.data["kg"], 0.5)
	assert_eq(r.data["remaining_kg"], 1.5)
	assert_false(r.data["removed"])
	assert_eq(inv.carried_by("npc:1").kg, 1.5)
	assert_eq(float(inv.consumed_kg_by_material()[&"meal"]), 0.5)
	assert_signal_emitted_with_parameters(inv, "items_changed", [m])
	_assert_ok()


func test_consume_whole_item_removes_it() -> void:
	var m := _carry(&"ration", 2.0, "npc:1")
	var r := inv.consume_item(m, 2.0 - Inventory.KG_EPSILON / 2.0)
	assert_true(r.ok)
	assert_true(r.data["removed"], "within epsilon of the whole stack")
	assert_eq(r.data["kg"], 2.0, "the whole stack is recorded")
	assert_null(inv.get_item(m))
	assert_null(inv.carried_by("npc:1"))
	assert_eq(inv.all_items().size(), 0)
	assert_eq(float(inv.consumed_kg_by_material()[&"ration"]), 2.0)
	_assert_ok()
	var g := inv.spawn_ground(&"meal", 1.0, Vector2i(1, 9))
	assert_true(inv.pick_up(g, "npc:1").ok, "hands are free again")


func test_consume_failures() -> void:
	var g := inv.spawn_ground(&"meal", 2.0, Vector2i(1, 9))
	var m := _carry(&"meal", 2.0, "npc:1")
	assert_eq(inv.consume_item("item:99", 1.0).code, &"unknown_item")
	assert_eq(inv.consume_item(g, 1.0).code, &"not_carried", "ground items cannot be eaten")
	assert_eq(inv.consume_item(m, 0.0).code, &"invalid_kg")
	assert_eq(inv.consume_item(m, -1.0).code, &"invalid_kg")
	assert_eq(inv.consume_item(m, NAN).code, &"invalid_kg")
	var too := inv.consume_item(m, 2.5)
	assert_eq(too.code, &"not_enough")
	assert_eq(too.data["available_kg"], 2.0)
	inv.deliver_to_site("npc:1", "job:1")
	assert_eq(inv.consume_item(m, 1.0).code, &"not_carried", "site items cannot be eaten")
	assert_eq(inv.get_item(m).kg, 2.0)
	_assert_ok()


func test_consume_from_site_failures() -> void:
	assert_eq(inv.consume_from_site("", &"mushroom", 1.0).code, &"invalid_job")
	assert_eq(inv.consume_from_site("job:1", &"mushroom", 0.0).code, &"invalid_kg")
	assert_eq(inv.consume_from_site("job:1", &"mushroom", 1.0).code, &"missing_input")
	var m := _carry(&"mushroom", 1.0, "npc:1")
	inv.deliver_to_site("npc:1", "job:1")
	assert_eq(inv.consume_from_site("job:1", &"meal", 1.0).code, &"missing_input", "wrong material")
	var r := inv.consume_from_site("job:1", &"mushroom", 1.0)
	assert_true(r.ok)
	assert_eq(r.data["item_ids"], [m] as Array[String])
	assert_eq(inv.site_kg("job:1"), 0.0)
	_assert_ok()


func test_random_walk_with_food() -> void:
	var bld: RefCounted = FB.new()
	var farm := Farming.new(bld, inv, ids)
	var kit := Kitchens.new(bld, inv)
	var farms: Array[String] = []
	for i in 3:
		farms.append(bld.place(&"farm_plot", Vector2i(10 + 3 * i, 9)))
	var k: String = bld.place(&"kitchen", Vector2i(20, 9))
	var rng := RandomNumberGenerator.new()
	rng.seed = 2024
	var mats: Array[StringName] = [&"dirt", &"mushroom", &"meal", &"ration"]
	var npcs := ["npc:1", "npc:2", "npc:3"]
	var jobs := ["job:1", "job:2", "job:3"]
	var crates := ["bld:90", "bld:91"]
	var counts := {"eat": 0, "cook": 0, "harvest": 0}
	var tick := 0
	for step in 600:
		tick += rng.randi_range(1, 900)
		farm.update(tick)
		var op := rng.randi_range(0, 13)
		var npc: String = npcs[rng.randi_range(0, 2)]
		var job: String = jobs[rng.randi_range(0, 2)]
		var tile := Vector2i(rng.randi_range(0, 5), 9)
		var r: CommandResult = null
		match op:
			0:
				inv.spawn_ground(mats[rng.randi_range(0, 3)], rng.randf_range(0.5, 20.0), tile)
			1:
				var ground := inv.items_at(tile)
				if not ground.is_empty():
					r = inv.pick_up(ground[0].id, npc, rng.randf_range(0.5, 15.0))
			2:
				r = inv.drop(npc, tile)
			3:
				r = inv.deliver_to_site(npc, job)
			4:
				r = inv.return_site_to_ground(job, tile)
			5:
				r = inv.store_in_crate(npc, crates[rng.randi_range(0, 1)])
			6:
				var inside := inv.crate_items(crates[rng.randi_range(0, 1)])
				if not inside.is_empty():
					r = inv.take_from_crate(inside[0].id, npc, rng.randf_range(0.5, 15.0))
			7, 8:
				if inv.carried_by(npc) == null:  # fetch food first (any ground stack)
					for it in inv.all_items():
						if it.holder == Inventory.Holder.GROUND and it.material != &"dirt":
							inv.pick_up(it.id, npc, rng.randf_range(0.5, 4.0))
							break
				var c := inv.carried_by(npc)
				if c != null:
					r = inv.consume_item(c.id, rng.randf_range(0.1, 3.0))
					if r.ok:
						counts["eat"] += 1
			9:
				if rng.randf() < 0.6 and inv.carried_by(npc) == null:  # haul cooking input
					var mid := inv.spawn_ground(&"mushroom", rng.randf_range(0.5, 2.5), tile)
					inv.pick_up(mid, npc)
					inv.deliver_to_site(npc, job)
				r = kit.cook(k, job, tile)
				if r.ok:
					counts["cook"] += 1
			10:
				var f: String = farms[rng.randi_range(0, 2)]
				r = farm.harvest(f, tile)
				if r.ok:
					counts["harvest"] += 1
				else:
					farm.plant(f)
			11:
				r = inv.consume_site(job)
			12:
				r = inv.empty_crate_to_ground(crates[rng.randi_range(0, 1)], tile)
			13:
				r = inv.consume_from_site(job, &"meal", rng.randf_range(0.5, 4.0))
		var errs := inv.check_conservation()
		errs.append_array(inv.verify_indexes())
		for it in inv.all_items():
			if it.kg <= 0.0:
				errs.append("%s has kg %f" % [it.id, it.kg])
		if not errs.is_empty():
			fail_test("step %d op %d: %s" % [step, op, errs.slice(0, 4)])
			return
	assert_gt(counts["eat"], 10, "eating exercised")
	assert_gt(counts["cook"], 3, "cooking exercised")
	assert_gt(counts["harvest"], 3, "harvesting exercised")
	var consumed := inv.consumed_kg_by_material()
	assert_true(consumed.has(&"mushroom"), "cooking input recorded as consumed: %s" % consumed)
	assert_true(inv.spawned_kg_by_material().has(&"meal"), "cooking output recorded as spawned")
	var snap := inv.to_snapshot()
	var inv2 := Inventory.new(StableIdAllocator.new())
	assert_eq(inv2.load_snapshot(bytes_to_var(var_to_bytes(snap))), 0)
	assert_eq(inv2.to_snapshot(), snap)
	assert_eq(inv2.check_conservation(), [] as Array[String])
	assert_eq(inv2.verify_indexes(), [] as Array[String])
