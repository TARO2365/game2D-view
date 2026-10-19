extends GutTest


func test_ids_are_sequential_per_category() -> void:
	var a := StableIdAllocator.new()
	assert_eq(a.allocate(&"npc"), "npc:1")
	assert_eq(a.allocate(&"npc"), "npc:2")
	assert_eq(a.allocate(&"job"), "job:1")


func test_ids_never_repeat() -> void:
	var a := StableIdAllocator.new()
	var seen := {}
	for i in 1000:
		var id := a.allocate(&"item")
		assert_false(seen.has(id), "duplicate %s" % id)
		seen[id] = true


func test_snapshot_round_trip_continues_sequence() -> void:
	var a := StableIdAllocator.new()
	a.allocate(&"npc")
	a.allocate(&"npc")
	a.allocate(&"vehicle")
	# Simulate save -> JSON -> load.
	var json := JSON.stringify(a.to_snapshot())
	var b := StableIdAllocator.new()
	b.load_snapshot(JSON.parse_string(json))
	assert_eq(b.allocate(&"npc"), "npc:3")
	assert_eq(b.allocate(&"vehicle"), "vehicle:2")
	assert_eq(b.allocate(&"quest"), "quest:1")


func test_parse_helpers() -> void:
	assert_eq(StableIdAllocator.category_of("npc:12"), &"npc")
	assert_true(StableIdAllocator.is_valid("npc:12"))
	assert_false(StableIdAllocator.is_valid("npc:"))
	assert_false(StableIdAllocator.is_valid("npc:0"))
	assert_false(StableIdAllocator.is_valid(":3"))
	assert_false(StableIdAllocator.is_valid("npc"))
