extends GutTest
## RoomMap: detection, types, incremental updates (M3 contract §3).

const FS := preload("res://tests/helpers/fs_util.gd")
const ROCK := {&"rock": 50.0}

var reg: TileRegistry
var g: WorldGrid
var b: Buildings
var rooms: RoomMap


func before_all() -> void:
	reg = TileRegistry.load_default()


func before_each() -> void:
	# Rows < 10 air (surface line 10), 10..62 dirt, row 63 bedrock.
	g = FS.make_grid(reg)
	b = Buildings.new(g, StableIdAllocator.new())
	rooms = RoomMap.new(g, b)


func _dig(r: Rect2i) -> void:
	assert_true(g.apply_edit(r, WorldGrid.Edit.DIG).ok, "dig %s" % r)


## First accepted material with the definition's kg.
func _mats(key: StringName) -> Dictionary:
	var d := b.def(key)
	return {d.materials[0]: d.kg} if d != null else ROCK


func _place(key: StringName, origin: Vector2i) -> String:
	var r := b.place(key, origin, _mats(key))
	assert_true(r.ok, "place %s: %s" % [key, r])
	return r.data.get("id", "")


func test_no_rooms_in_fresh_world() -> void:
	assert_eq(rooms.room_count(), 0)
	assert_eq(rooms.room_at(Vector2i(5, 5)), {}, "open sky")
	assert_eq(rooms.room_at(Vector2i(5, 20)), {}, "solid")
	assert_eq(rooms.room_at(Vector2i(-1, 20)), {}, "out of bounds")


func test_closed_box_is_a_room() -> void:
	watch_signals(rooms)
	_dig(Rect2i(10, 20, 11, 3))
	assert_signal_emitted(rooms, "rooms_changed")
	var room := rooms.room_at(Vector2i(12, 21))
	assert_eq(room["size"], 33)
	assert_eq(room["type"], &"room")
	assert_eq(room["bounds"], Rect2i(10, 20, 11, 3))
	assert_eq(room["building_ids"], [] as Array[String])
	assert_eq(rooms.room_at(Vector2i(20, 22))["id"], room["id"])
	assert_eq(rooms.all_rooms().size(), 1)
	assert_eq(rooms.room_tiles(room["id"]).size(), 33)


func test_door_splits_and_bounds_rooms() -> void:
	_dig(Rect2i(10, 20, 11, 3))
	var door := _place(&"door", Vector2i(15, 22))
	assert_eq(rooms.room_count(), 2)
	var left := rooms.room_at(Vector2i(10, 20))
	var right := rooms.room_at(Vector2i(20, 22))
	assert_eq(left["size"], 15)
	assert_eq(right["size"], 15)
	assert_ne(left["id"], right["id"])
	assert_eq(rooms.room_at(Vector2i(15, 21)), {}, "door tiles are not part of a room")
	assert_false(left["building_ids"].has(door))
	b.remove(door)
	assert_eq(rooms.room_count(), 1)
	assert_eq(rooms.room_at(Vector2i(10, 20))["size"], 33)


func test_open_to_sky_is_not_a_room() -> void:
	_dig(Rect2i(10, 20, 11, 3))
	_dig(Rect2i(12, 11, 1, 9))
	assert_eq(rooms.room_at(Vector2i(12, 21))["size"], 33 + 9, "still closed: row 10 is dirt")
	assert_eq(rooms.room_count(), 1)
	_dig(Rect2i(12, 10, 1, 1))
	assert_eq(rooms.room_at(Vector2i(12, 21)), {}, "open to the sky")
	assert_eq(rooms.room_count(), 0)
	# Walling the shaft closes it again.
	g.apply_edit(Rect2i(12, 15, 1, 1), WorldGrid.Edit.BUILD_WALL)
	assert_eq(rooms.room_at(Vector2i(12, 21))["size"], 33 + 4)


func test_room_touching_world_border_is_open() -> void:
	_dig(Rect2i(0, 30, 4, 3))
	assert_eq(rooms.room_at(Vector2i(2, 31)), {})
	_dig(Rect2i(60, 40, 4, 3))
	assert_eq(rooms.room_at(Vector2i(61, 41)), {})
	_dig(Rect2i(30, 59, 3, 3))
	assert_eq(rooms.room_at(Vector2i(31, 60)).get("size", 0), 9, "walled by bedrock, not the border: closed")
	assert_eq(rooms.room_count(), 1)


func test_size_limit() -> void:
	_dig(Rect2i(10, 20, 8, 16))  # 128 tiles
	assert_eq(rooms.room_at(Vector2i(12, 25))["size"], RoomMap.MAX_ROOM_TILES)
	_dig(Rect2i(18, 20, 1, 1))  # 129
	assert_eq(rooms.room_at(Vector2i(12, 25)), {}, "too big = open cave")
	g.apply_edit(Rect2i(18, 20, 1, 1), WorldGrid.Edit.BUILD_WALL)
	assert_eq(rooms.room_at(Vector2i(12, 25))["size"], 128)


func test_type_by_furniture() -> void:
	_dig(Rect2i(10, 20, 11, 3))
	var table := _place(&"table", Vector2i(11, 22))
	assert_eq(rooms.room_at(Vector2i(12, 20))["type"], &"dining")
	var crate := _place(&"crate", Vector2i(14, 22))
	assert_eq(rooms.room_at(Vector2i(12, 20))["type"], &"dining", "dining beats storage (M4a order)")
	var bed := _place(&"bed", Vector2i(18, 22))
	var room := rooms.room_at(Vector2i(12, 20))
	assert_eq(room["type"], &"bedroom", "bedroom beats all")
	assert_eq(room["building_ids"], [table, crate, bed] as Array[String])
	assert_eq(room["size"], 33, "furniture tiles are part of the room")
	b.remove(bed)
	assert_eq(rooms.room_at(Vector2i(12, 20))["type"], &"dining")
	b.remove(table)
	assert_eq(rooms.room_at(Vector2i(12, 20))["type"], &"storage")
	b.remove(crate)
	assert_eq(rooms.room_at(Vector2i(12, 20))["type"], &"room")


## Every combination of the tagged buildings (2^5 = 32) in one room:
## bedroom > kitchen > dining > storage > farm > room (M4a §6).
func test_type_priority_all_combinations() -> void:
	_dig(Rect2i(10, 20, 11, 3))  # dirt floor at row 23: farm plots are allowed
	var spots := [
		[&"bed", Vector2i(10, 22), &"bedroom"],
		[&"kitchen", Vector2i(12, 22), &"kitchen"],
		[&"table", Vector2i(14, 22), &"dining"],
		[&"crate", Vector2i(16, 22), &"storage"],
		[&"farm_plot", Vector2i(17, 22), &"farm"],
	]
	var full := RoomMap.new(g, b)
	for mask in 32:
		var placed: Array[String] = []
		var expected := &"room"
		for i in spots.size():
			if mask & (1 << i):
				placed.append(_place(spots[i][0], spots[i][1]))
				if expected == &"room":
					expected = spots[i][2]  # spots are listed in priority order
		var room := rooms.room_at(Vector2i(20, 20))
		assert_eq(room.get("type"), expected, "mask %d" % mask)
		assert_eq(room.get("building_ids"), placed, "mask %d" % mask)
		full.rebuild_all()
		assert_eq(_canonical(rooms), _canonical(full), "incremental == full, mask %d" % mask)
		for id in placed:
			b.remove(id)
	assert_eq(rooms.room_at(Vector2i(20, 20)).get("type"), &"room")


func test_furniture_type_per_side_of_door() -> void:
	_dig(Rect2i(10, 20, 11, 3))
	_place(&"door", Vector2i(15, 22))
	_place(&"bed", Vector2i(11, 22))
	_place(&"crate", Vector2i(19, 22))
	assert_eq(rooms.room_at(Vector2i(10, 20))["type"], &"bedroom")
	assert_eq(rooms.room_at(Vector2i(20, 20))["type"], &"storage")


func test_hole_in_wall_merges_and_wall_splits() -> void:
	_dig(Rect2i(10, 20, 5, 3))
	_dig(Rect2i(16, 20, 5, 3))
	assert_eq(rooms.room_count(), 2)
	_dig(Rect2i(15, 21, 1, 1))
	assert_eq(rooms.room_count(), 1)
	assert_eq(rooms.room_at(Vector2i(10, 20))["size"], 31)
	g.apply_edit(Rect2i(15, 21, 1, 1), WorldGrid.Edit.BUILD_WALL)
	assert_eq(rooms.room_count(), 2)
	assert_eq(rooms.room_at(Vector2i(10, 20))["size"], 15)
	g.apply_edit(Rect2i(15, 21, 1, 1), WorldGrid.Edit.DECONSTRUCT_WALL)
	assert_eq(rooms.room_count(), 1)
	# Digging into the big open area opens it.
	_dig(Rect2i(20, 10, 1, 10))
	assert_eq(rooms.room_count(), 0)


func test_rooms_changed_rect_covers_change() -> void:
	_dig(Rect2i(10, 20, 11, 3))
	watch_signals(rooms)
	_place(&"crate", Vector2i(20, 22))
	assert_signal_emit_count(rooms, "rooms_changed", 1, "one recompute per placement")
	var params: Array = get_signal_parameters(rooms, "rooms_changed")
	var rect: Rect2i = params[0]
	assert_true(rect.encloses(Rect2i(10, 20, 11, 3)), "covers the whole re-typed room: %s" % rect)
	g.apply_edit(Rect2i(40, 40, 1, 1), WorldGrid.Edit.BUILD_WALL)  # inside dirt: nothing happens
	g.apply_edit(Rect2i(40, 5, 1, 1), WorldGrid.Edit.DIG)  # air: nothing to dig
	_dig(Rect2i(40, 30, 1, 1))  # isolated pocket: a new 1-tile room
	assert_signal_emit_count(rooms, "rooms_changed", 2)
	assert_signal_emitted_with_parameters(rooms, "rooms_changed", [Rect2i(39, 29, 3, 3)])


func test_rebuild_all_matches() -> void:
	_dig(Rect2i(10, 20, 11, 3))
	_dig(Rect2i(30, 30, 4, 4))
	_place(&"door", Vector2i(15, 22))
	var before := _canonical(rooms)
	rooms.rebuild_all()
	assert_eq(_canonical(rooms), before)
	assert_eq(before.size(), 3)


func test_incremental_equals_full_rebuild_randomized() -> void:
	g = FS.make_grid(reg, Vector2i(40, 40))
	b = Buildings.new(g, StableIdAllocator.new())
	rooms = RoomMap.new(g, b)
	var reference := RoomMap.new(g, b)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261020
	var keys: Array[StringName] = [&"door", &"crate", &"bed", &"table", &"farm_plot", &"kitchen"]
	var max_rooms := 0
	var placed := 0
	var lost := [0]
	b.building_lost.connect(func(_id: String, _k: StringName, _o: Vector2i, _m: Dictionary) -> void: lost[0] += 1)
	for step in 600:
		var roll := rng.randi_range(0, 99)
		var p := Vector2i(rng.randi_range(1, 38), rng.randi_range(9, 38))
		var size := Vector2i(rng.randi_range(1, 4), rng.randi_range(1, 4))
		if roll < 40:
			g.apply_edit(Rect2i(p, size), WorldGrid.Edit.DIG)
		elif roll < 60:
			g.apply_edit(Rect2i(p, Vector2i(rng.randi_range(1, 2), rng.randi_range(1, 3))),
					WorldGrid.Edit.BUILD_WALL)
		elif roll < 70:
			g.apply_edit(Rect2i(p, size), WorldGrid.Edit.DECONSTRUCT_WALL)
		elif roll < 90:
			# Drop the origin onto the first floor below p so placements succeed often.
			while p.y < 38 and not g.is_solid_at(p + Vector2i.DOWN):
				p.y += 1
			var key := keys[rng.randi_range(0, keys.size() - 1)]
			if b.place(key, p, _mats(key)).ok:
				placed += 1
		else:
			var all := b.all_ids()
			if not all.is_empty():
				var id := all[rng.randi_range(0, all.size() - 1)]
				if roll < 95:
					b.remove(id)
				else:  # take away its floor -> building_lost
					var bd := b.get_building(id)
					var fp := b.footprint(bd["key"], bd["origin"])
					var under := Rect2i(fp.position.x, fp.end.y, 1, 1)
					g.apply_edit(under, WorldGrid.Edit.DIG)
					g.apply_edit(under, WorldGrid.Edit.DECONSTRUCT_WALL)
		reference.rebuild_all()
		var inc := _canonical(rooms)
		var full := _canonical(reference)
		if inc != full:
			fail_test("step %d: incremental rooms differ from full rebuild\n%s\n%s" % [step, inc, full])
			return
		max_rooms = maxi(max_rooms, inc.size())
	assert_gt(max_rooms, 2, "the random walk produced rooms")
	assert_gt(placed, 20, "the random walk placed buildings")
	assert_gt(lost[0], 0, "the random walk removed buildings by support loss")
	gut.p("max rooms %d, placed %d, lost %d" % [max_rooms, placed, lost[0]])


func test_large_generated_world_timing() -> void:
	g = WorldGenerator.generate(12345, Vector2i(1024, 384), reg)
	b = Buildings.new(g, StableIdAllocator.new())
	var t0 := Time.get_ticks_usec()
	rooms = RoomMap.new(g, b)  # full build
	var build_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var reference := _canonical(rooms)
	# Incremental edits stay local and cheap.
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	t0 = Time.get_ticks_usec()
	for i in 50:
		var p := Vector2i(rng.randi_range(1, 1020), rng.randi_range(100, 380))
		g.apply_edit(Rect2i(p, Vector2i(3, 3)), WorldGrid.Edit.DIG)
	var edit_ms := (Time.get_ticks_usec() - t0) / 1000.0 / 50.0
	var inc := _canonical(rooms)
	rooms.rebuild_all()
	assert_eq(inc, _canonical(rooms), "incremental == full on a generated world")
	gut.p("1024x384: full room build %.1f ms (%d rooms), avg dig+recompute %.2f ms" %
			[build_ms, reference.size(), edit_ms])
	assert_lt(edit_ms, 50.0, "incremental recompute is bounded")


func _canonical(m: RoomMap) -> Array[String]:
	var out: Array[String] = []
	for r in m.all_rooms():
		out.append("%s|%s|%s|%s" % [r["type"], r["bounds"], m.room_tiles(r["id"]), r["building_ids"]])
	out.sort()
	return out
