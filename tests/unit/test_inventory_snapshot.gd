extends GutTest

var ids: StableIdAllocator
var inv: Inventory


func before_each() -> void:
	ids = StableIdAllocator.new()
	inv = Inventory.new(ids)


func _populate() -> void:
	var a := inv.spawn_ground(&"dirt", 120.0, Vector2i(1, 9))
	var b := inv.spawn_ground(&"rock", 60.0, Vector2i(2, 9))
	inv.spawn_ground(&"iron_ore", 50.0, Vector2i(3, 9))
	inv.pick_up(a, "npc:1", 70.0)
	inv.pick_up(b, "npc:2")
	inv.deliver_to_site("npc:2", "job:4")
	inv.spawn_ground(&"rock", 40.0, Vector2i(4, 9))
	var c := inv.items_at(Vector2i(4, 9))[0].id
	inv.pick_up(c, "npc:3")
	inv.deliver_to_site("npc:3", "job:5")
	inv.consume_site("job:5")


func test_round_trip_through_bytes() -> void:
	_populate()
	var snap := inv.to_snapshot()
	var bytes := var_to_bytes(snap)
	var restored: Variant = bytes_to_var(bytes)
	assert_eq(typeof(restored), TYPE_DICTIONARY)
	var inv2 := Inventory.new(StableIdAllocator.new())
	watch_signals(inv2)
	inv2.load_snapshot(restored)
	assert_signal_emitted(inv2, "items_changed")
	assert_eq(inv2.to_snapshot(), snap)
	assert_eq(var_to_bytes(inv2.to_snapshot()), bytes, "byte-identical re-save")
	assert_eq(inv2.carried_by("npc:1").kg, 70.0)
	assert_eq(inv2.site_kg("job:4"), 60.0)
	assert_eq(inv2.consumed_kg_by_material(), inv.consumed_kg_by_material())
	assert_eq(inv2.spawned_kg_by_material(), inv.spawned_kg_by_material())
	assert_eq(inv2.check_conservation(), [] as Array[String])


func test_snapshot_uses_plain_types() -> void:
	_populate()
	var snap := inv.to_snapshot()
	for e: Dictionary in snap["items"]:
		assert_eq(typeof(e["id"]), TYPE_STRING)
		assert_eq(typeof(e["material"]), TYPE_STRING)
		assert_eq(typeof(e["kg"]), TYPE_FLOAT)
		assert_eq(typeof(e["holder"]), TYPE_INT)
		assert_eq(typeof(e["tile"]), TYPE_VECTOR2I)
		assert_eq(typeof(e["holder_id"]), TYPE_STRING)
	for k: Variant in snap["spawned"]:
		assert_eq(typeof(k), TYPE_STRING)


func test_load_continues_carry_state() -> void:
	_populate()
	var inv2 := Inventory.new(ids)
	inv2.load_snapshot(inv.to_snapshot())
	var g := inv2.spawn_ground(&"dirt", 5.0, Vector2i.ZERO)
	assert_eq(inv2.pick_up(g, "npc:1").code, &"already_carrying")
	assert_true(inv2.drop("npc:1", Vector2i(9, 9)).ok)
	assert_true(inv2.pick_up(g, "npc:1").ok)
	assert_eq(inv2.check_conservation(), [] as Array[String])


func test_load_sanitizes_junk() -> void:
	var junk := {
		"items": [
			{"id": "item:1", "material": "dirt", "kg": 10.0, "holder": 0, "tile": Vector2i(1, 1), "holder_id": ""},
			{"id": "item:1", "material": "dirt", "kg": 99.0, "holder": 0, "tile": Vector2i(1, 1), "holder_id": ""},
			{"id": "npc:2", "material": "dirt", "kg": 10.0, "holder": 0, "tile": Vector2i(1, 1), "holder_id": ""},
			{"id": "item:x", "material": "dirt", "kg": 10.0, "holder": 0, "tile": Vector2i(1, 1), "holder_id": ""},
			{"id": "item:3", "material": "", "kg": 10.0, "holder": 0, "tile": Vector2i(1, 1), "holder_id": ""},
			{"id": "item:4", "material": "dirt", "kg": -3.0, "holder": 0, "tile": Vector2i(1, 1), "holder_id": ""},
			{"id": "item:5", "material": "dirt", "kg": NAN, "holder": 0, "tile": Vector2i(1, 1), "holder_id": ""},
			{"id": "item:6", "material": "dirt", "kg": 10.0, "holder": 7, "tile": Vector2i(1, 1), "holder_id": ""},
			{"id": "item:7", "material": "dirt", "kg": 10.0, "holder": 1, "tile": Vector2i(1, 1), "holder_id": ""},
			{"id": "item:8", "material": "rock", "kg": 20, "holder": 1, "tile": Vector2i(-1, -1), "holder_id": "npc:1"},
			{"id": "item:9", "material": "rock", "kg": 20.0, "holder": 1, "tile": Vector2i(-1, -1), "holder_id": "npc:1"},
			{"id": "item:10", "material": "rock", "kg": 5.0, "holder": 2, "tile": Vector2i(-1, -1), "holder_id": "job:1"},
			{"id": "item:11", "material": "rock", "kg": 5.0, "holder": 0, "tile": "nope", "holder_id": ""},
			{"id": 12, "material": "rock", "kg": 5.0, "holder": 0},
			"garbage",
			null,
			42,
		],
		"spawned": {"dirt": 1.0e9},
		"consumed": {"rock": 15.0, "dirt": -4.0, "": 3.0, "iron_ore": "x"},
	}
	inv.load_snapshot(junk)
	var kept := []
	for it in inv.all_items():
		kept.append(it.id)
	assert_eq(kept, ["item:1", "item:8", "item:10"])
	assert_eq(inv.get_item("item:1").kg, 10.0, "first duplicate wins")
	assert_eq(inv.carried_by("npc:1").id, "item:8", "one stack per NPC")
	assert_eq(inv.consumed_kg_by_material(), {&"rock": 15.0})
	assert_eq(inv.spawned_kg_by_material(), {&"dirt": 10.0, &"rock": 40.0}, "rebuilt = total + consumed")
	assert_eq(inv.check_conservation(), [] as Array[String])


func test_load_garbage_snapshot_is_empty() -> void:
	_populate()
	inv.load_snapshot({})
	assert_eq(inv.all_items().size(), 0)
	inv.load_snapshot({"items": "nope", "spawned": [], "consumed": 5})
	assert_eq(inv.all_items().size(), 0)
	assert_null(inv.carried_by("npc:1"))
	assert_eq(inv.check_conservation(), [] as Array[String])
