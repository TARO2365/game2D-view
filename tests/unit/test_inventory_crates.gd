extends GutTest
## Inventory holder CRATE (M3 contract §4): store/take/empty, split on take,
## conservation across ground/npc/site/crate, snapshot compatibility.

var ids: StableIdAllocator
var inv: Inventory


func before_each() -> void:
	ids = StableIdAllocator.new()
	inv = Inventory.new(ids)


func _assert_conserved(msg: String = "") -> void:
	assert_eq(inv.check_conservation(), [] as Array[String], "conservation %s" % msg)


func _carry(material: StringName, kg: float, npc: String) -> String:
	var id := inv.spawn_ground(material, kg, Vector2i(0, 9))
	return inv.pick_up(id, npc, kg).data["item_id"]


func test_store_in_crate() -> void:
	var a := _carry(&"rock", 50.0, "npc:1")
	watch_signals(inv)
	var r := inv.store_in_crate("npc:1", "bld:3")
	assert_true(r.ok, str(r))
	assert_eq(r.data["item_id"], a)
	assert_eq(r.data["kg"], 50.0)
	assert_eq(r.data["crate_kg"], 50.0)
	assert_null(inv.carried_by("npc:1"))
	var it := inv.get_item(a)
	assert_eq(it.holder, Inventory.Holder.CRATE)
	assert_eq(it.holder_id, "bld:3")
	assert_eq(it.tile, Vector2i(-1, -1))
	assert_eq(inv.items_at(Vector2i(0, 9)).size(), 0, "crate items are not ground items")
	assert_signal_emitted_with_parameters(inv, "items_changed", [a], 0)
	var b := _carry(&"dirt", 30.0, "npc:1")
	assert_eq(inv.store_in_crate("npc:1", "bld:3").data["crate_kg"], 80.0)
	assert_eq(inv.crate_kg("bld:3"), 80.0)
	assert_eq(inv.crate_kg("bld:4"), 0.0)
	var list := inv.crate_items("bld:3")
	assert_eq(list.size(), 2)
	assert_eq(list[0].id, a)
	assert_eq(list[1].id, b)
	assert_eq(inv.crate_items("").size(), 0)
	_assert_conserved()


func test_store_failures() -> void:
	assert_eq(inv.store_in_crate("npc:1", "bld:1").code, &"not_carrying")
	var a := _carry(&"rock", 50.0, "npc:1")
	assert_eq(inv.store_in_crate("npc:1", "").code, &"invalid_building")
	assert_eq(inv.carried_by("npc:1").id, a, "failed store keeps the item in hands")
	_assert_conserved()


func test_take_whole_stack() -> void:
	var a := _carry(&"rock", 50.0, "npc:1")
	inv.store_in_crate("npc:1", "bld:1")
	var r := inv.take_from_crate(a, "npc:2")
	assert_true(r.ok, str(r))
	assert_eq(r.data["item_id"], a, "no split -> same id")
	assert_false(r.data["split"])
	assert_eq(r.data["building_id"], "bld:1")
	assert_eq(inv.carried_by("npc:2").id, a)
	assert_eq(inv.get_item(a).holder, Inventory.Holder.NPC)
	assert_eq(inv.crate_kg("bld:1"), 0.0)
	_assert_conserved()


func test_take_splits_like_pick_up() -> void:
	var a := _carry(&"dirt", 250.0, "npc:1")
	inv.store_in_crate("npc:1", "bld:1")
	watch_signals(inv)
	var r := inv.take_from_crate(a, "npc:2", 100.0)
	assert_true(r.ok)
	assert_true(r.data["split"])
	assert_eq(r.data["source_id"], a)
	var new_id: String = r.data["item_id"]
	assert_ne(new_id, a)
	assert_eq(inv.get_item(new_id).kg, 100.0)
	assert_eq(inv.get_item(new_id).holder, Inventory.Holder.NPC)
	assert_eq(inv.get_item(a).kg, 150.0)
	assert_eq(inv.get_item(a).holder, Inventory.Holder.CRATE, "rest stays in the crate")
	assert_eq(inv.get_item(a).holder_id, "bld:1")
	assert_eq(inv.crate_kg("bld:1"), 150.0)
	assert_signal_emitted_with_parameters(inv, "items_changed", [a], 0)
	assert_signal_emitted_with_parameters(inv, "items_changed", [new_id], 1)
	assert_signal_emit_count(inv, "items_changed", 2)
	_assert_conserved()


func test_take_default_capacity() -> void:
	var a := _carry(&"dirt", 500.0, "npc:1")
	inv.store_in_crate("npc:1", "bld:1")
	var r := inv.take_from_crate(a, "npc:1")
	assert_eq(inv.get_item(r.data["item_id"]).kg, Inventory.CARRY_CAPACITY_KG)


func test_take_failures() -> void:
	var a := _carry(&"rock", 50.0, "npc:1")
	inv.store_in_crate("npc:1", "bld:1")
	var g := inv.spawn_ground(&"rock", 5.0, Vector2i(1, 9))
	assert_eq(inv.take_from_crate("item:99", "npc:1").code, &"unknown_item")
	assert_eq(inv.take_from_crate(a, "").code, &"invalid_npc")
	assert_eq(inv.take_from_crate(g, "npc:1").code, &"not_in_crate")
	assert_eq(inv.take_from_crate(a, "npc:1", 0.0).code, &"invalid_kg")
	assert_eq(inv.take_from_crate(a, "npc:1", NAN).code, &"invalid_kg")
	inv.pick_up(g, "npc:1")
	assert_eq(inv.take_from_crate(a, "npc:1").code, &"already_carrying")
	assert_eq(inv.take_from_crate(g, "npc:2").code, &"not_in_crate", "carried item")
	assert_eq(inv.pick_up(a, "npc:2").code, &"not_on_ground", "crate items cannot be picked up")
	assert_eq(inv.crate_kg("bld:1"), 50.0)
	_assert_conserved()


func test_empty_crate_to_ground() -> void:
	var a := _carry(&"rock", 50.0, "npc:1")
	inv.store_in_crate("npc:1", "bld:1")
	var b := _carry(&"dirt", 20.0, "npc:1")
	inv.store_in_crate("npc:1", "bld:1")
	var c := _carry(&"dirt", 7.0, "npc:1")
	inv.store_in_crate("npc:1", "bld:2")
	watch_signals(inv)
	var r := inv.empty_crate_to_ground("bld:1", Vector2i(4, 9))
	assert_true(r.ok)
	assert_eq(r.data["kg"], 70.0)
	assert_eq(r.data["item_ids"], [a, b] as Array[String])
	for id in [a, b]:
		var it := inv.get_item(id)
		assert_eq(it.holder, Inventory.Holder.GROUND, "ids are kept")
		assert_eq(it.tile, Vector2i(4, 9))
		assert_eq(it.holder_id, "")
	assert_eq(inv.ground_kg_at(Vector2i(4, 9)), 70.0)
	assert_eq(inv.crate_kg("bld:1"), 0.0)
	assert_eq(inv.crate_kg("bld:2"), 7.0, "other crates untouched")
	assert_eq(inv.get_item(c).holder, Inventory.Holder.CRATE)
	assert_signal_emit_count(inv, "items_changed", 2)
	var e := inv.empty_crate_to_ground("bld:1", Vector2i(4, 9))
	assert_true(e.ok, "an empty crate empties fine")
	assert_eq(e.data["kg"], 0.0)
	assert_eq(inv.empty_crate_to_ground("", Vector2i.ZERO).code, &"invalid_building")
	_assert_conserved()


func test_random_walk_conservation_with_crates() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242
	var mats: Array[StringName] = [&"dirt", &"rock", &"iron_ore"]
	var npcs := ["npc:1", "npc:2", "npc:3"]
	var jobs := ["job:1", "job:2", "job:3"]
	var crates := ["bld:1", "bld:2"]
	var ok_count := 0
	var crate_ops := 0
	for step in 500:
		var op := rng.randi_range(0, 9)
		var npc: String = npcs[rng.randi_range(0, npcs.size() - 1)]
		var job: String = jobs[rng.randi_range(0, jobs.size() - 1)]
		var crate: String = crates[rng.randi_range(0, crates.size() - 1)]
		var tile := Vector2i(rng.randi_range(0, 5), 9)
		var r: CommandResult = null
		match op:
			0:
				inv.spawn_ground(mats[rng.randi_range(0, 2)], rng.randf_range(0.5, 300.0), tile)
			1:
				var ground := inv.items_at(tile)
				var target := "item:999999" if ground.is_empty() else ground[0].id
				r = inv.pick_up(target, npc, rng.randf_range(1.0, 250.0))
			2:
				r = inv.drop(npc, tile)
			3:
				r = inv.deliver_to_site(npc, job)
			4:
				r = inv.consume_site(job)
			5:
				r = inv.return_site_to_ground(job, tile)
			6, 7:
				r = inv.store_in_crate(npc, crate)
			8:
				var inside := inv.crate_items(crate)
				var target := "item:999999" if inside.is_empty() else inside[rng.randi_range(0, inside.size() - 1)].id
				r = inv.take_from_crate(target, npc, rng.randf_range(1.0, 250.0))
			9:
				if rng.randf() < 0.3:
					r = inv.empty_crate_to_ground(crate, tile)
				else:
					var all := inv.all_items()
					if not all.is_empty():
						r = inv.take_from_crate(all[rng.randi_range(0, all.size() - 1)].id, npc)
		if r != null and r.ok:
			ok_count += 1
			if op >= 6:
				crate_ops += 1
		var errs := inv.check_conservation()
		errs.append_array(inv.verify_indexes())
		var naive := _naive_mismatch(jobs, crates)
		if not naive.is_empty():
			errs.append(naive)
		if not errs.is_empty():
			fail_test("step %d op %d: %s" % [step, op, errs])
			return
		var held := {}
		var in_crates := {}
		for it in inv.all_items():
			if it.kg <= 0.0:
				fail_test("step %d: %s has kg %f" % [step, it.id, it.kg])
				return
			if it.holder == Inventory.Holder.NPC:
				held[it.holder_id] = int(held.get(it.holder_id, 0)) + 1
			elif it.holder == Inventory.Holder.CRATE:
				in_crates[it.holder_id] = float(in_crates.get(it.holder_id, 0.0)) + it.kg
		for n: String in npcs:
			var h: int = held.get(n, 0)
			if h > 1 or (h == 1) != (inv.carried_by(n) != null):
				fail_test("step %d: %s holds %d stacks" % [step, n, h])
				return
		for c: String in crates:
			if absf(float(in_crates.get(c, 0.0)) - inv.crate_kg(c)) > Inventory.KG_EPSILON:
				fail_test("step %d: crate_kg(%s) disagrees with holders" % [step, c])
				return
	assert_gt(ok_count, 50, "the walk exercised real operations")
	assert_gt(crate_ops, 20, "the walk exercised crate operations")
	var snap := inv.to_snapshot()
	var inv2 := Inventory.new(StableIdAllocator.new())
	assert_eq(inv2.load_snapshot(bytes_to_var(var_to_bytes(snap))), 0)
	assert_eq(inv2.to_snapshot(), snap)
	assert_eq(inv2.check_conservation(), [] as Array[String])
	assert_eq(inv2.verify_indexes(), [] as Array[String], "indexes rebuilt on load")
	for c: String in crates:
		assert_eq(inv2.crate_kg(c), inv.crate_kg(c))
	for x in 6:
		assert_eq(inv2.ground_kg_at(Vector2i(x, 9)), inv.ground_kg_at(Vector2i(x, 9)))


## Indexed queries must equal a full scan in id order, bit for bit (the
## pre-M3-QA-6 implementation). Returns "" when everything matches.
func _naive_mismatch(jobs: Array, crates: Array) -> String:
	var all := inv.all_items()
	var ground := {}
	var keyed := {}
	for it in all:
		if it.holder == Inventory.Holder.GROUND:
			if not ground.has(it.tile):
				ground[it.tile] = []
			ground[it.tile].append(it)
		elif it.holder == Inventory.Holder.SITE or it.holder == Inventory.Holder.CRATE:
			var k := "%d|%s" % [it.holder, it.holder_id]
			if not keyed.has(k):
				keyed[k] = []
			keyed[k].append(it)
	for x in range(-1, 7):
		var t := Vector2i(x, 9)
		var want: Array = ground.get(t, [])
		if _ids_of(inv.items_at(t)) != _ids_of(want) or inv.ground_kg_at(t) != _sum(want):
			return "ground %s differs from a full scan" % t
	for j: String in jobs:
		var want: Array = keyed.get("%d|%s" % [Inventory.Holder.SITE, j], [])
		if _ids_of(inv.site_items(j)) != _ids_of(want) or inv.site_kg(j) != _sum(want):
			return "site %s differs from a full scan" % j
	for c: String in crates:
		var want: Array = keyed.get("%d|%s" % [Inventory.Holder.CRATE, c], [])
		if _ids_of(inv.crate_items(c)) != _ids_of(want) or inv.crate_kg(c) != _sum(want):
			return "crate %s differs from a full scan" % c
	return ""


func _ids_of(list: Array) -> Array:
	var out := []
	for it: ItemStack in list:
		out.append(it.id)
	return out


func _sum(list: Array) -> float:
	var s := 0.0
	for it: ItemStack in list:
		s += it.kg
	return s


func test_returned_arrays_are_copies() -> void:
	var a := _carry(&"rock", 50.0, "npc:1")
	inv.store_in_crate("npc:1", "bld:1")
	inv.spawn_ground(&"dirt", 5.0, Vector2i(3, 9))
	inv.crate_items("bld:1").clear()
	inv.items_at(Vector2i(3, 9)).clear()
	inv.all_items().clear()
	assert_eq(inv.crate_items("bld:1").size(), 1)
	assert_eq(inv.items_at(Vector2i(3, 9)).size(), 1)
	assert_eq(inv.all_items().size(), 2)
	assert_eq(inv.crate_items("bld:1")[0].id, a)
	assert_eq(inv.verify_indexes(), [] as Array[String])


func test_verify_indexes_detects_tampering() -> void:
	var g := inv.spawn_ground(&"dirt", 5.0, Vector2i(3, 9))
	inv.ground_kg_at(Vector2i(3, 9))  # builds the cache
	assert_eq(inv.verify_indexes(), [] as Array[String])
	inv.get_item(g).tile = Vector2i(4, 9)  # illegal outside Inventory: index is now stale
	assert_false(inv.verify_indexes().is_empty())


func test_crate_items_round_trip() -> void:
	var a := _carry(&"rock", 50.0, "npc:1")
	inv.store_in_crate("npc:1", "bld:2")
	_carry(&"dirt", 10.0, "npc:1")
	var snap := inv.to_snapshot()
	var bytes := var_to_bytes(snap)
	var inv2 := Inventory.new(StableIdAllocator.new())
	assert_eq(inv2.load_snapshot(bytes_to_var(bytes)), 0)
	assert_eq(var_to_bytes(inv2.to_snapshot()), bytes, "byte-identical re-save")
	assert_eq(inv2.get_item(a).holder, Inventory.Holder.CRATE)
	assert_eq(inv2.crate_kg("bld:2"), 50.0)
	assert_eq(inv2.carried_by("npc:1").kg, 10.0)
	assert_eq(inv2.check_conservation(), [] as Array[String])


func test_old_m2_snapshot_loads_unchanged() -> void:
	# Literal M2 (save v2) inventory snapshot: holders 0..2 only, no crates.
	var m2 := {
		"items": [
			{"id": "item:1", "material": "dirt", "kg": 50.0, "holder": 0, "tile": Vector2i(1, 9), "holder_id": ""},
			{"id": "item:2", "material": "rock", "kg": 70.0, "holder": 1, "tile": Vector2i(-1, -1), "holder_id": "npc:1"},
			{"id": "item:4", "material": "rock", "kg": 30.0, "holder": 2, "tile": Vector2i(-1, -1), "holder_id": "job:3"},
		],
		"spawned": {"dirt": 50.0, "rock": 140.0},
		"consumed": {"rock": 40.0},
	}
	assert_eq(inv.load_snapshot(m2.duplicate(true)), 0)
	assert_eq(inv.to_snapshot(), m2, "M2 snapshot re-saves identically")
	assert_eq(inv.carried_by("npc:1").id, "item:2")
	assert_eq(inv.site_kg("job:3"), 30.0)
	assert_eq(inv.crate_items("bld:1").size(), 0)
	_assert_conserved()


func test_load_sanitizes_crate_junk() -> void:
	var junk := {
		"items": [
			{"id": "item:1", "material": "rock", "kg": 10.0, "holder": 3, "tile": Vector2i(-1, -1), "holder_id": "bld:1"},
			{"id": "item:2", "material": "rock", "kg": 10.0, "holder": 3, "tile": Vector2i(-1, -1), "holder_id": ""},
			{"id": "item:3", "material": "rock", "kg": 10.0, "holder": 3, "tile": Vector2i(-1, -1), "holder_id": 5},
			{"id": "item:4", "material": "rock", "kg": 10.0, "holder": 4, "tile": Vector2i(-1, -1), "holder_id": "bld:1"},
			{"id": "item:5", "material": "rock", "kg": 10.0, "holder": 3, "tile": Vector2i(2, 2), "holder_id": "bld:1"},
		],
		"consumed": {},
	}
	assert_eq(inv.load_snapshot(junk), 3)
	assert_eq(inv.crate_kg("bld:1"), 20.0)
	assert_eq(inv.get_item("item:5").tile, Vector2i(-1, -1), "crate items carry no tile")
	_assert_conserved()
