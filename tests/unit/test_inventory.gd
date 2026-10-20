extends GutTest

var ids: StableIdAllocator
var inv: Inventory


func before_each() -> void:
	ids = StableIdAllocator.new()
	inv = Inventory.new(ids)


func _assert_conserved(msg: String = "") -> void:
	var errs := inv.check_conservation()
	assert_eq(errs, [] as Array[String], "conservation %s" % msg)


func test_spawn_ground() -> void:
	watch_signals(inv)
	var id := inv.spawn_ground(&"dirt", 50.0, Vector2i(3, 9))
	assert_eq(id, "item:1")
	var it := inv.get_item(id)
	assert_not_null(it)
	assert_eq(it.material, &"dirt")
	assert_eq(it.kg, 50.0)
	assert_eq(it.holder, Inventory.Holder.GROUND)
	assert_eq(it.tile, Vector2i(3, 9))
	assert_eq(inv.items_at(Vector2i(3, 9)).size(), 1)
	assert_eq(inv.ground_kg_at(Vector2i(3, 9)), 50.0)
	assert_eq(inv.ground_kg_at(Vector2i(4, 9)), 0.0)
	assert_signal_emitted_with_parameters(inv, "items_changed", [id], 0)
	assert_eq(inv.spawned_kg_by_material(), {&"dirt": 50.0})
	_assert_conserved()


func test_spawn_rejects_invalid() -> void:
	assert_eq(inv.spawn_ground(&"dirt", 0.0, Vector2i.ZERO), "")
	assert_eq(inv.spawn_ground(&"dirt", -5.0, Vector2i.ZERO), "")
	assert_eq(inv.spawn_ground(&"dirt", INF, Vector2i.ZERO), "")
	assert_eq(inv.spawn_ground(&"", 5.0, Vector2i.ZERO), "")
	assert_eq(inv.all_items().size(), 0)
	assert_eq(ids.peek_next(&"item"), 1, "no id wasted")


func test_stacks_never_merge() -> void:
	inv.spawn_ground(&"rock", 50.0, Vector2i(1, 1))
	inv.spawn_ground(&"rock", 50.0, Vector2i(1, 1))
	assert_eq(inv.items_at(Vector2i(1, 1)).size(), 2)
	assert_eq(inv.ground_kg_at(Vector2i(1, 1)), 100.0)


func test_pick_up_whole_and_drop() -> void:
	var id := inv.spawn_ground(&"rock", 50.0, Vector2i(2, 9))
	var r := inv.pick_up(id, "npc:1")
	assert_true(r.ok, str(r))
	assert_eq(r.data["item_id"], id, "no split -> same id")
	assert_false(r.data["split"])
	var it := inv.carried_by("npc:1")
	assert_eq(it.id, id)
	assert_eq(it.holder, Inventory.Holder.NPC)
	assert_eq(it.holder_id, "npc:1")
	assert_eq(inv.ground_kg_at(Vector2i(2, 9)), 0.0)
	var d := inv.drop("npc:1", Vector2i(7, 9))
	assert_true(d.ok)
	assert_eq(d.data["item_id"], id)
	assert_null(inv.carried_by("npc:1"))
	assert_eq(inv.get_item(id).tile, Vector2i(7, 9))
	assert_eq(inv.get_item(id).holder_id, "")
	_assert_conserved()


func test_pick_up_splits_heavy_stack() -> void:
	var id := inv.spawn_ground(&"dirt", 250.0, Vector2i(0, 9))
	watch_signals(inv)
	var r := inv.pick_up(id, "npc:1", 100.0)
	assert_true(r.ok)
	assert_true(r.data["split"])
	var new_id: String = r.data["item_id"]
	assert_ne(new_id, id)
	assert_eq(new_id, "item:2")
	assert_eq(inv.get_item(new_id).kg, 100.0)
	assert_eq(inv.get_item(id).kg, 150.0)
	assert_eq(inv.get_item(id).holder, Inventory.Holder.GROUND)
	assert_eq(inv.carried_by("npc:1").id, new_id)
	assert_signal_emitted_with_parameters(inv, "items_changed", [id], 0)
	assert_signal_emitted_with_parameters(inv, "items_changed", [new_id], 1)
	assert_signal_emit_count(inv, "items_changed", 2)
	_assert_conserved()


func test_pick_up_default_capacity() -> void:
	var id := inv.spawn_ground(&"dirt", 500.0, Vector2i(0, 9))
	var r := inv.pick_up(id, "npc:1")
	assert_eq(inv.get_item(r.data["item_id"]).kg, Inventory.CARRY_CAPACITY_KG)


func test_pick_up_failures() -> void:
	var a := inv.spawn_ground(&"dirt", 50.0, Vector2i(0, 9))
	var b := inv.spawn_ground(&"dirt", 50.0, Vector2i(1, 9))
	assert_eq(inv.pick_up("item:99", "npc:1").code, &"unknown_item")
	assert_eq(inv.pick_up(a, "").code, &"invalid_npc")
	assert_eq(inv.pick_up(a, "npc:1", 0.0).code, &"invalid_kg")
	assert_eq(inv.pick_up(a, "npc:1", -1.0).code, &"invalid_kg")
	assert_true(inv.pick_up(a, "npc:1").ok)
	assert_eq(inv.pick_up(b, "npc:1").code, &"already_carrying")
	assert_eq(inv.pick_up(a, "npc:2").code, &"not_on_ground")
	inv.deliver_to_site("npc:1", "job:1")
	assert_eq(inv.pick_up(a, "npc:2").code, &"not_on_ground", "site items cannot be picked")
	_assert_conserved()


func test_drop_and_deliver_failures() -> void:
	assert_eq(inv.drop("npc:1", Vector2i.ZERO).code, &"not_carrying")
	assert_eq(inv.deliver_to_site("npc:1", "job:1").code, &"not_carrying")
	var a := inv.spawn_ground(&"dirt", 50.0, Vector2i(0, 9))
	inv.pick_up(a, "npc:1")
	assert_eq(inv.deliver_to_site("npc:1", "").code, &"invalid_job")
	assert_eq(inv.carried_by("npc:1").id, a, "failed deliver keeps item in hands")
	assert_eq(inv.consume_site("job:9").code, &"nothing_at_site")
	assert_eq(inv.return_site_to_ground("job:9", Vector2i.ZERO).code, &"nothing_at_site")


func test_deliver_and_consume() -> void:
	var a := inv.spawn_ground(&"rock", 30.0, Vector2i(0, 9))
	var b := inv.spawn_ground(&"rock", 30.0, Vector2i(1, 9))
	inv.pick_up(a, "npc:1")
	var r := inv.deliver_to_site("npc:1", "job:5")
	assert_true(r.ok)
	assert_eq(r.data["site_kg"], 30.0)
	inv.pick_up(b, "npc:1", 20.0)
	inv.deliver_to_site("npc:1", "job:5")
	assert_eq(inv.site_kg("job:5"), 50.0)
	assert_eq(inv.site_items("job:5").size(), 2)
	assert_eq(inv.get_item(a).holder, Inventory.Holder.SITE)
	assert_eq(inv.get_item(a).holder_id, "job:5")
	_assert_conserved("before consume")
	watch_signals(inv)
	var c := inv.consume_site("job:5")
	assert_true(c.ok)
	assert_almost_eq(float(c.data["kg"]), 50.0, 0.0001)
	assert_null(inv.get_item(a))
	assert_eq(inv.site_kg("job:5"), 0.0)
	assert_signal_emitted_with_parameters(inv, "items_changed", [a], 0)
	assert_almost_eq(float(inv.consumed_kg_by_material()[&"rock"]), 50.0, 0.0001)
	assert_almost_eq(float(inv.total_kg_by_material()[&"rock"]), 10.0, 0.0001)
	_assert_conserved("after consume")


func test_return_site_to_ground() -> void:
	var a := inv.spawn_ground(&"rock", 30.0, Vector2i(0, 9))
	inv.pick_up(a, "npc:1")
	inv.deliver_to_site("npc:1", "job:2")
	var r := inv.return_site_to_ground("job:2", Vector2i(5, 9))
	assert_true(r.ok)
	assert_eq(r.data["kg"], 30.0)
	assert_eq(inv.get_item(a).holder, Inventory.Holder.GROUND)
	assert_eq(inv.get_item(a).tile, Vector2i(5, 9))
	assert_eq(inv.get_item(a).holder_id, "")
	assert_eq(inv.site_kg("job:2"), 0.0)
	_assert_conserved()


func test_all_items_ordered_by_id_number() -> void:
	for i in 12:
		inv.spawn_ground(&"dirt", 1.0, Vector2i(i, 0))
	var list := inv.all_items()
	assert_eq(list.size(), 12)
	for i in list.size():
		assert_eq(list[i].id, "item:%d" % (i + 1))


func test_random_walk_conservation() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var mats: Array[StringName] = [&"dirt", &"rock", &"iron_ore"]
	var npcs := ["npc:1", "npc:2", "npc:3"]
	var jobs := ["job:1", "job:2", "job:3", "job:4"]
	var ok_count := 0
	for step in 500:
		var op := rng.randi_range(0, 6)
		var npc: String = npcs[rng.randi_range(0, npcs.size() - 1)]
		var job: String = jobs[rng.randi_range(0, jobs.size() - 1)]
		var tile := Vector2i(rng.randi_range(0, 7), 9)
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
			6:
				var all := inv.all_items()
				if not all.is_empty():
					r = inv.pick_up(all[rng.randi_range(0, all.size() - 1)].id, npc, rng.randf_range(1.0, 250.0))
		if r != null and r.ok:
			ok_count += 1
		var errs := inv.check_conservation()
		if not errs.is_empty():
			fail_test("step %d op %d: %s" % [step, op, errs])
			return
		# Each NPC carries at most one stack and carried_by agrees with holders.
		var held := {}
		for it in inv.all_items():
			if it.kg <= 0.0:
				fail_test("step %d: %s has kg %f" % [step, it.id, it.kg])
				return
			if it.holder == Inventory.Holder.NPC:
				held[it.holder_id] = int(held.get(it.holder_id, 0)) + 1
		for n: String in npcs:
			var h: int = held.get(n, 0)
			if h > 1 or (h == 1) != (inv.carried_by(n) != null):
				fail_test("step %d: %s holds %d stacks, carried_by=%s" % [step, n, h, inv.carried_by(n)])
				return
	assert_gt(ok_count, 50, "the walk exercised real operations")
	# Round-trip after the walk preserves everything.
	var snap := inv.to_snapshot()
	var inv2 := Inventory.new(StableIdAllocator.new())
	inv2.load_snapshot(bytes_to_var(var_to_bytes(snap)))
	assert_eq(inv2.to_snapshot(), snap)
	assert_eq(inv2.check_conservation(), [] as Array[String])
