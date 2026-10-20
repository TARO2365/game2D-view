extends GutTest
## CrateStorage (M3 contract §4): crate list, filters, capacity, bookings,
## find_crate determinism, crate removal, snapshots.
##
## Buildings (World Agent, src/world/buildings.gd) did not exist when this was
## written, so FakeBuildings below implements only the contract members that
## CrateStorage uses. Lead: these tests can keep the fake after the merge.


class FakeDef extends Resource:
	var storage_kg: float = 0.0

	func _init(kg: float = 0.0) -> void:
		storage_kg = kg


class FakeBuildings extends RefCounted:
	signal buildings_changed(rect: Rect2i)
	signal building_lost(id: String, key: StringName, origin: Vector2i, materials: Dictionary)

	var defs: Dictionary = {
		&"crate": FakeDef.new(2000.0),
		&"small_crate": FakeDef.new(100.0),
		&"bed": FakeDef.new(0.0),
	}
	var placed: Dictionary = {}   # id -> {id, key, origin, materials}
	var next_num := 1

	func def(key: StringName) -> FakeDef:
		return defs.get(key)

	func get_building(id: String) -> Dictionary:
		var b: Variant = placed.get(id)
		return (b as Dictionary).duplicate() if b != null else {}

	func all_ids() -> Array[String]:
		var out: Array[String] = []
		for id: String in placed:
			out.append(id)
		return out

	func count() -> int:
		return placed.size()

	## Like Buildings.load_snapshot: replaces everything, emits no signal.
	func load_silently(entries: Dictionary) -> void:
		placed = entries.duplicate(true)

	func place(key: StringName, origin: Vector2i) -> String:
		var id := "bld:%d" % next_num
		next_num += 1
		placed[id] = {"id": id, "key": key, "origin": origin, "materials": {&"rock": 50.0}}
		buildings_changed.emit(Rect2i(origin, Vector2i.ONE))
		return id

	func remove(id: String) -> void:
		var b: Dictionary = placed[id]
		placed.erase(id)
		buildings_changed.emit(Rect2i(b["origin"], Vector2i.ONE))

	func lose(id: String) -> void:
		var b: Dictionary = placed[id]
		placed.erase(id)
		building_lost.emit(id, b["key"], b["origin"], b["materials"])
		buildings_changed.emit(Rect2i(b["origin"], Vector2i.ONE))


var bld: FakeBuildings
var inv: Inventory
var cs: CrateStorage


func before_each() -> void:
	bld = FakeBuildings.new()
	inv = Inventory.new(StableIdAllocator.new())
	cs = CrateStorage.new(bld, inv)


func _store(material: StringName, kg: float, crate: String) -> String:
	var id := inv.spawn_ground(material, kg, Vector2i(0, 9))
	var item_id: String = inv.pick_up(id, "npc:99", kg).data["item_id"]
	inv.store_in_crate("npc:99", crate)
	return item_id


func test_crate_ids_only_storage_buildings() -> void:
	watch_signals(cs)
	var a := bld.place(&"crate", Vector2i(5, 9))
	bld.place(&"bed", Vector2i(1, 9))
	var c := bld.place(&"small_crate", Vector2i(9, 9))
	for i in 8:
		bld.place(&"bed", Vector2i(20 + i, 9))
	var d := bld.place(&"crate", Vector2i(0, 9))  # bld:12
	assert_eq(cs.crate_ids(), [a, c, d] as Array[String], "ordered by id number")
	assert_true(cs.is_crate(a))
	assert_false(cs.is_crate("bld:2"), "bed")
	assert_false(cs.is_crate("bld:99"))
	assert_false(cs.is_crate(""))
	assert_signal_emit_count(cs, "crates_changed", 3, "one per new crate")
	assert_signal_emitted_with_parameters(cs, "crates_changed", [a], 0)


func test_filters() -> void:
	var a := bld.place(&"crate", Vector2i(5, 9))
	assert_eq(cs.get_filter(a), [] as Array[StringName])
	assert_true(cs.accepts(a, &"rock"), "[] accepts all")
	assert_false(cs.accepts(a, &""))
	watch_signals(cs)
	var r := cs.set_filter(a, [&"rock", &"dirt", &"rock"] as Array[StringName])
	assert_true(r.ok, str(r))
	assert_eq(cs.get_filter(a), [&"dirt", &"rock"] as Array[StringName], "sorted, unique")
	assert_true(cs.accepts(a, &"dirt"))
	assert_false(cs.accepts(a, &"iron_ore"))
	assert_signal_emitted_with_parameters(cs, "crates_changed", [a])
	cs.get_filter(a).append(&"iron_ore")
	assert_false(cs.accepts(a, &"iron_ore"), "get_filter returns a copy")
	assert_true(cs.set_filter(a, [] as Array[StringName]).ok)
	assert_true(cs.accepts(a, &"iron_ore"))
	assert_eq(cs.set_filter("bld:99", [] as Array[StringName]).code, &"not_crate")
	assert_eq(cs.set_filter(bld.place(&"bed", Vector2i(1, 9)), [] as Array[StringName]).code, &"not_crate")
	assert_eq(cs.set_filter(a, [&"rock", &""] as Array[StringName]).code, &"invalid_material")
	assert_eq(cs.get_filter(a), [] as Array[StringName], "failed set keeps the old filter")
	assert_false(cs.accepts("bld:99", &"rock"))


func test_capacity_and_bookings() -> void:
	var a := bld.place(&"small_crate", Vector2i(5, 9))   # 100 kg
	assert_eq(cs.free_capacity(a), 100.0)
	_store(&"rock", 30.0, a)
	assert_eq(cs.free_capacity(a), 70.0, "items in the crate count")
	var r := cs.book(a, 50.0, "job:1")
	assert_true(r.ok, str(r))
	assert_eq(cs.booked_crate("job:1"), a)
	assert_eq(cs.booked_kg(a), 50.0)
	assert_eq(cs.free_capacity(a), 20.0)
	var full := cs.book(a, 30.0, "job:2")
	assert_eq(full.code, &"no_capacity")
	assert_almost_eq(float(full.data["free"]), 20.0, 0.0001)
	assert_eq(cs.booked_crate("job:2"), "")
	assert_true(cs.book(a, 70.0, "job:1").ok, "re-book on the same crate counts its own booking")
	assert_eq(cs.booked_kg(a), 70.0, "re-book replaces, never adds")
	assert_eq(cs.free_capacity(a), 0.0)
	assert_eq(cs.book(a, 71.0, "job:1").code, &"no_capacity")
	assert_eq(cs.booked_kg(a), 70.0, "failed re-book keeps the old booking")
	cs.release("job:1")
	cs.release("job:1")
	cs.release("job:404")
	assert_eq(cs.booked_crate("job:1"), "")
	assert_eq(cs.booked_kg(a), 0.0)
	assert_eq(cs.free_capacity(a), 70.0)
	assert_eq(cs.free_capacity("bld:99"), 0.0)
	_store(&"rock", 150.0, a)  # overfilled by direct Inventory use
	assert_eq(cs.free_capacity(a), 0.0, "never negative")


func test_rebook_moves_between_crates() -> void:
	var a := bld.place(&"crate", Vector2i(5, 9))
	var b := bld.place(&"crate", Vector2i(8, 9))
	assert_true(cs.book(a, 100.0, "job:1").ok)
	assert_true(cs.book(b, 40.0, "job:1").ok)
	assert_eq(cs.booked_crate("job:1"), b)
	assert_eq(cs.booked_kg(a), 0.0)
	assert_eq(cs.booked_kg(b), 40.0)


func test_book_failures() -> void:
	var a := bld.place(&"crate", Vector2i(5, 9))
	assert_eq(cs.book(a, 10.0, "").code, &"invalid_job")
	assert_eq(cs.book(a, 0.0, "job:1").code, &"invalid_kg")
	assert_eq(cs.book(a, -1.0, "job:1").code, &"invalid_kg")
	assert_eq(cs.book(a, NAN, "job:1").code, &"invalid_kg")
	assert_eq(cs.book(a, INF, "job:1").code, &"invalid_kg")
	assert_eq(cs.book("bld:99", 10.0, "job:1").code, &"not_crate")
	assert_eq(cs.book(bld.place(&"bed", Vector2i(1, 9)), 10.0, "job:1").code, &"not_crate")
	assert_eq(cs.booked_crate("job:1"), "")


func test_find_crate_nearest_and_ties() -> void:
	var far := bld.place(&"crate", Vector2i(20, 9))
	var right := bld.place(&"crate", Vector2i(13, 9))   # d = 3 from (10, 9)
	var left := bld.place(&"crate", Vector2i(7, 9))     # d = 3
	var up := bld.place(&"crate", Vector2i(10, 6))      # d = 3, smaller y
	var near := Vector2i(10, 9)
	assert_eq(cs.find_crate(&"rock", 50.0, near), up, "tie: smaller y first")
	cs.set_filter(up, [&"dirt"] as Array[StringName])
	assert_eq(cs.find_crate(&"rock", 50.0, near), left, "tie: then smaller x")
	assert_eq(cs.find_crate(&"dirt", 50.0, near), up)
	cs.book(left, 1990.0, "job:1")
	assert_eq(cs.find_crate(&"rock", 50.0, near), right, "no room in left")
	assert_eq(cs.find_crate(&"rock", 10.0, near), left, "10 kg still fits")
	cs.book(right, 2000.0, "job:2")
	assert_eq(cs.find_crate(&"rock", 50.0, near), far)
	assert_eq(cs.find_crate(&"rock", 2001.0, near), "", "too heavy for any crate")
	assert_eq(cs.find_crate(&"rock", 0.0, near), "")
	assert_eq(cs.find_crate(&"rock", NAN, near), "")
	for i in 5:
		assert_eq(cs.find_crate(&"rock", 50.0, near), far, "deterministic")


func test_find_crate_none() -> void:
	assert_eq(cs.find_crate(&"rock", 10.0, Vector2i.ZERO), "")
	bld.place(&"bed", Vector2i(1, 9))
	assert_eq(cs.find_crate(&"rock", 10.0, Vector2i.ZERO), "")


func test_is_stored() -> void:
	var a := bld.place(&"crate", Vector2i(5, 9))
	var in_crate := _store(&"rock", 10.0, a)
	var g := inv.spawn_ground(&"rock", 10.0, Vector2i(1, 9))
	assert_true(cs.is_stored(inv.get_item(in_crate)))
	assert_false(cs.is_stored(inv.get_item(g)))
	assert_false(cs.is_stored(null))


func test_removed_crate_drops_filter_and_bookings() -> void:
	var a := bld.place(&"crate", Vector2i(5, 9))
	var b := bld.place(&"crate", Vector2i(8, 9))
	cs.set_filter(a, [&"rock"] as Array[StringName])
	cs.book(a, 100.0, "job:1")
	cs.book(a, 50.0, "job:2")
	cs.book(b, 20.0, "job:3")
	var item := _store(&"rock", 40.0, a)
	watch_signals(cs)
	bld.remove(a)
	assert_eq(cs.crate_ids(), [b] as Array[String])
	assert_eq(cs.booked_crate("job:1"), "")
	assert_eq(cs.booked_crate("job:2"), "")
	assert_eq(cs.booked_crate("job:3"), b, "other crates keep their bookings")
	assert_eq(cs.booked_kg(a), 0.0)
	assert_eq(cs.get_filter(a), [] as Array[StringName])
	assert_eq(cs.free_capacity(a), 0.0)
	assert_signal_emitted_with_parameters(cs, "crates_changed", [a])
	assert_signal_emit_count(cs, "crates_changed", 1)
	assert_eq(inv.get_item(item).holder, Inventory.Holder.CRATE,
			"CrateStorage never mutates Inventory; JobManager empties the crate")
	assert_eq(cs.to_snapshot()["bookings"].size(), 1)


func test_lost_crate_drops_bookings() -> void:
	var a := bld.place(&"crate", Vector2i(5, 9))
	cs.book(a, 100.0, "job:1")
	cs.set_filter(a, [&"rock"] as Array[StringName])
	watch_signals(cs)
	bld.lose(a)
	assert_eq(cs.booked_crate("job:1"), "")
	assert_eq(cs.crate_ids(), [] as Array[String])
	assert_eq(cs.to_snapshot(), {"filters": [], "bookings": []})
	assert_signal_emit_count(cs, "crates_changed", 1, "lost + changed report the crate once")


func test_existing_crates_known_at_construction() -> void:
	var a := bld.place(&"crate", Vector2i(5, 9))
	var cs2 := CrateStorage.new(bld, inv)
	cs2.book(a, 10.0, "job:1")
	watch_signals(cs2)
	bld.remove(a)
	assert_eq(cs2.booked_crate("job:1"), "")
	assert_signal_emitted_with_parameters(cs2, "crates_changed", [a])


func test_snapshot_round_trip() -> void:
	var a := bld.place(&"crate", Vector2i(5, 9))
	var b := bld.place(&"crate", Vector2i(8, 9))
	for i in 9:
		bld.place(&"crate", Vector2i(30 + i, 9))
	var k := "bld:11"
	cs.set_filter(b, [&"rock", &"dirt"] as Array[StringName])
	cs.set_filter(k, [&"iron_ore"] as Array[StringName])
	cs.book(a, 100.0, "job:10")
	cs.book(b, 25.5, "job:2")
	cs.book(k, 1.0, "job:3")
	var snap := cs.to_snapshot()
	assert_eq(snap["filters"], [
		{"building_id": b, "materials": ["dirt", "rock"]},
		{"building_id": k, "materials": ["iron_ore"]},
	])
	assert_eq(snap["bookings"][0]["job_id"], "job:2", "ordered by id number")
	assert_eq(snap["bookings"][2]["job_id"], "job:10")
	for e: Dictionary in snap["filters"]:
		assert_eq(typeof(e["building_id"]), TYPE_STRING)
		for m: Variant in e["materials"]:
			assert_eq(typeof(m), TYPE_STRING)
	var bytes := var_to_bytes(snap)
	var cs2 := CrateStorage.new(bld, inv)
	watch_signals(cs2)
	assert_eq(cs2.load_snapshot(bytes_to_var(bytes)), 0)
	assert_signal_emitted_with_parameters(cs2, "crates_changed", [""])
	assert_eq(var_to_bytes(cs2.to_snapshot()), bytes, "byte-identical re-save")
	assert_eq(cs2.get_filter(b), [&"dirt", &"rock"] as Array[StringName])
	assert_eq(cs2.booked_crate("job:10"), a)
	assert_eq(cs2.booked_kg(b), 25.5)
	assert_eq(cs2.free_capacity(a), 1900.0)


func test_load_sanitizes_junk() -> void:
	var a := bld.place(&"crate", Vector2i(5, 9))
	var bed := bld.place(&"bed", Vector2i(1, 9))
	var junk := {
		"filters": [
			{"building_id": a, "materials": ["rock", "", 5, "rock", "dirt"]},   # 2 junk materials
			{"building_id": a, "materials": ["iron_ore"]},                       # duplicate crate
			{"building_id": bed, "materials": ["rock"]},                         # not a crate
			{"building_id": "bld:99", "materials": ["rock"]},                    # unknown
			{"building_id": a},                                                  # (duplicate anyway)
			{"materials": ["rock"]},
			"garbage",
		],
		"bookings": [
			{"job_id": "job:1", "building_id": a, "kg": 10},
			{"job_id": "job:1", "building_id": a, "kg": 5.0},       # duplicate job
			{"job_id": "", "building_id": a, "kg": 5.0},
			{"job_id": "job:2", "building_id": bed, "kg": 5.0},
			{"job_id": "job:3", "building_id": "bld:99", "kg": 5.0},
			{"job_id": "job:4", "building_id": a, "kg": -5.0},
			{"job_id": "job:5", "building_id": a, "kg": NAN},
			{"job_id": "job:6", "building_id": a, "kg": "x"},
			{"job_id": 7, "building_id": a, "kg": 5.0},
			null,
		],
	}
	assert_eq(cs.load_snapshot(junk), 2 + 6 + 9, "junk materials + rejected filters + rejected bookings")
	assert_eq(cs.get_filter(a), [&"dirt", &"rock"] as Array[StringName])
	assert_eq(cs.booked_crate("job:1"), a)
	assert_eq(cs.booked_kg(a), 10.0)
	assert_eq(cs.to_snapshot()["bookings"].size(), 1)


func test_load_garbage_snapshot_is_empty() -> void:
	var a := bld.place(&"crate", Vector2i(5, 9))
	cs.book(a, 10.0, "job:1")
	cs.set_filter(a, [&"rock"] as Array[StringName])
	assert_eq(cs.load_snapshot({}), 0)
	assert_eq(cs.to_snapshot(), {"filters": [], "bookings": []})
	assert_eq(cs.load_snapshot({"filters": "x", "bookings": 5}), 0)
	assert_eq(cs.free_capacity(a), 2000.0)


func test_cache_follows_silent_buildings_load() -> void:
	var a := bld.place(&"crate", Vector2i(5, 9))
	assert_eq(cs.crate_ids(), [a] as Array[String])
	# Buildings.load_snapshot emits nothing; a different building count must
	# still refresh the cached crate list.
	bld.load_silently({
		"bld:7": {"id": "bld:7", "key": &"crate", "origin": Vector2i(2, 9), "materials": {}},
		"bld:3": {"id": "bld:3", "key": &"small_crate", "origin": Vector2i(4, 9), "materials": {}},
	})
	assert_eq(cs.crate_ids(), ["bld:3", "bld:7"] as Array[String])
	assert_eq(cs.free_capacity("bld:3"), 100.0)
	assert_eq(cs.free_capacity(a), 0.0)
	assert_eq(cs.find_crate(&"rock", 10.0, Vector2i(0, 9)), "bld:7")
	# Same count, different ids: CrateStorage.load_snapshot (save order) refreshes.
	bld.load_silently({
		"bld:9": {"id": "bld:9", "key": &"crate", "origin": Vector2i(1, 9), "materials": {}},
		"bld:10": {"id": "bld:10", "key": &"bed", "origin": Vector2i(3, 9), "materials": {}},
	})
	cs.load_snapshot({})
	assert_eq(cs.crate_ids(), ["bld:9"] as Array[String])
	cs.crate_ids().clear()
	assert_eq(cs.crate_ids().size(), 1, "crate_ids returns a copy")


## Reference implementation of find_crate (pre-M3-QA-6 full scan): nearest
## by Manhattan distance to the origin, ties smaller y, x, id number.
func _brute_find(material: StringName, kg: float, near: Vector2i) -> String:
	var best := ""
	var bd := 0
	var bo := Vector2i.ZERO
	for id in cs.crate_ids():  # id order
		if not cs.accepts(id, material) or cs.free_capacity(id) + Inventory.KG_EPSILON < kg:
			continue
		var o: Vector2i = bld.get_building(id)["origin"]
		var d := absi(o.x - near.x) + absi(o.y - near.y)
		if best.is_empty() or d < bd or (d == bd and (o.y < bo.y or (o.y == bo.y and o.x < bo.x))):
			best = id
			bd = d
			bo = o
	return best


func test_find_crate_matches_full_scan() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var mats: Array[StringName] = [&"dirt", &"rock", &"iron_ore"]
	for i in 40:
		var r := rng.randf()
		var key := &"crate" if r < 0.6 else (&"small_crate" if r < 0.8 else &"bed")
		bld.place(key, Vector2i(rng.randi_range(0, 12), rng.randi_range(0, 12)))  # many ties
	var cids := cs.crate_ids()
	for id in cids:
		if rng.randf() < 0.4:
			cs.set_filter(id, [mats[rng.randi_range(0, 2)]] as Array[StringName])
		if rng.randf() < 0.5:
			_store(mats[rng.randi_range(0, 2)], rng.randf_range(10.0, 1900.0), id)
		if rng.randf() < 0.3:
			cs.book(id, rng.randf_range(1.0, 500.0), "job:%d" % rng.randi_range(1, 1000))
	var found := 0
	for q in 400:
		var m := mats[rng.randi_range(0, 2)]
		var kg := rng.randf_range(1.0, 2600.0)  # > 2000 never fits
		var near := Vector2i(rng.randi_range(-3, 15), rng.randi_range(-3, 15))
		var want := _brute_find(m, kg, near)
		var got := cs.find_crate(m, kg, near)
		if got != want:
			fail_test("query %d (%s %.1f kg near %s): got %s, full scan %s" % [q, m, kg, near, got, want])
			return
		if not got.is_empty():
			found += 1
	assert_gt(found, 100, "the queries found crates")
	assert_gt(400 - found, 10, "and some found none")
	assert_eq(inv.verify_indexes(), [] as Array[String])


## Micro-benchmark for M3-QA-6 (60 crates, 2000 stacks: 1000 in crates, 1000
## on the ground). Prints per-call costs; the bounds are loose (CI noise) but
## far below the 23.5 ms per find_crate measured by QA before the fix.
func test_bench_crate_queries() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	for i in 60:
		bld.place(&"crate", Vector2i(30 + i * 15, 20 + (i % 5)))
	for i in 30:
		bld.place(&"bed", Vector2i(36 + i * 15, 20))
	var cids := cs.crate_ids()
	for i in 1000:
		_store(&"dirt" if rng.randf() < 0.6 else &"rock", rng.randf_range(1.0, 2.0), cids[i % cids.size()])
	for i in 1000:
		inv.spawn_ground(&"dirt", rng.randf_range(10.0, 150.0), Vector2i(rng.randi_range(0, 900), 9))
	for i in 60:
		cs.book(cids[i], 10.0, "job:%d" % (i + 1))
	assert_eq(inv.all_items().size(), 2000)
	var n := 1000
	var t0 := Time.get_ticks_usec()
	for i in n:
		cs.crate_ids()
	var t1 := Time.get_ticks_usec()
	for i in n:
		cs.free_capacity(cids[i % cids.size()])
	var t2 := Time.get_ticks_usec()
	for i in n:
		cs.find_crate(&"dirt", 50.0, Vector2i((i * 37) % 900, 9))
	var t3 := Time.get_ticks_usec()
	for i in n:
		inv.crate_kg(cids[i % cids.size()])
		inv.ground_kg_at(Vector2i(i % 900, 9))
	var t4 := Time.get_ticks_usec()
	var ids_ms := (t1 - t0) / 1000.0 / n
	var free_ms := (t2 - t1) / 1000.0 / n
	var find_ms := (t3 - t2) / 1000.0 / n
	var kg_ms := (t4 - t3) / 1000.0 / n
	gut.p("M3-QA-6 bench (60 crates, 2000 stacks), ms per call: crate_ids %.4f  free_capacity %.4f  find_crate %.4f  crate_kg+ground_kg_at %.4f" % [
			ids_ms, free_ms, find_ms, kg_ms])
	assert_lt(find_ms, 1.0, "find_crate well under 1 ms (was 23.5 ms)")
	assert_lt(free_ms, 0.1, "free_capacity well under 0.1 ms (was 0.37 ms)")
	assert_lt(ids_ms, 0.1, "crate_ids well under 0.1 ms (was 1.34 ms)")
