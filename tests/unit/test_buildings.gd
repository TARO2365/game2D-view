extends GutTest
## Buildings: definitions, placement rules, occupancy, removal, support loss,
## snapshots (M3 contract §2).

const FS := preload("res://tests/helpers/fs_util.gd")
const ROCK := {&"rock": 50.0}

var reg: TileRegistry
var g: WorldGrid
var ids: StableIdAllocator
var b: Buildings


func before_all() -> void:
	reg = TileRegistry.load_default()


func before_each() -> void:
	# Rows < 10 air, 10..62 dirt, row 63 bedrock. Corridor x 10..20, rows 20..22
	# (3 tall, dirt ceiling at row 19, dirt floor at row 23).
	g = FS.make_grid(reg)
	g.apply_edit(Rect2i(10, 20, 11, 3), WorldGrid.Edit.DIG)
	ids = StableIdAllocator.new()
	b = Buildings.new(g, ids)


func _place(key: StringName, origin: Vector2i, mats: Dictionary = ROCK) -> String:
	var r := b.place(key, origin, mats)
	assert_true(r.ok, "place %s at %s: %s" % [key, origin, r])
	return r.data.get("id", "")


func test_defs_match_contract() -> void:
	var door := b.def(&"door")
	assert_eq(door.size, Vector2i(1, 3))
	assert_true(door.is_door)
	assert_true(door.needs_floor)
	assert_eq(door.materials, [&"rock"] as Array[StringName])
	assert_almost_eq(door.kg, 50.0, 0.001)
	assert_eq(door.work_ticks, 30)
	var crate := b.def(&"crate")
	assert_eq(crate.size, Vector2i.ONE)
	assert_eq(crate.materials, [&"rock", &"dirt"] as Array[StringName])
	assert_almost_eq(crate.storage_kg, 2000.0, 0.001)
	assert_eq(crate.room_tag, &"storage")
	assert_eq(crate.work_ticks, 20)
	var bed := b.def(&"bed")
	assert_eq(bed.size, Vector2i(2, 1))
	assert_eq(bed.room_tag, &"bedroom")
	assert_eq(bed.materials, [&"rock", &"dirt"] as Array[StringName])
	var table := b.def(&"table")
	assert_eq(table.size, Vector2i(2, 1))
	assert_eq(table.room_tag, &"dining")
	assert_eq(table.materials, [&"rock"] as Array[StringName])
	for d in [bed, table]:
		assert_almost_eq(d.kg, 50.0, 0.001)
		assert_eq(d.work_ticks, 30)
		assert_false(d.is_door)
	assert_null(b.def(&"nope"))
	assert_eq(b.registry.all_defs().size(), 4)


func test_footprint_grows_up_from_bottom_left() -> void:
	assert_eq(b.footprint(&"door", Vector2i(15, 22)), Rect2i(15, 20, 1, 3))
	assert_eq(b.footprint(&"bed", Vector2i(11, 22)), Rect2i(11, 22, 2, 1))
	assert_eq(b.footprint(&"crate", Vector2i(3, 4)), Rect2i(3, 4, 1, 1))
	assert_eq(b.footprint(&"nope", Vector2i(3, 4)), Rect2i())


func test_can_place_basic_codes() -> void:
	assert_true(b.can_place(&"crate", Vector2i(20, 22)).ok)
	assert_true(b.can_place(&"crate", Vector2i(5, 9)).ok, "on the surface")
	assert_eq(b.can_place(&"nope", Vector2i(20, 22)).code, &"unknown_key")
	assert_eq(b.can_place(&"crate", Vector2i(-1, 5)).code, &"out_of_bounds")
	assert_eq(b.can_place(&"door", Vector2i(3, 1)).code, &"out_of_bounds", "top above the world")
	assert_eq(b.can_place(&"bed", Vector2i(63, 9)).code, &"out_of_bounds", "right edge")
	assert_eq(b.can_place(&"crate", Vector2i(5, 20)).code, &"blocked", "inside dirt")
	assert_eq(b.can_place(&"bed", Vector2i(20, 22)).code, &"blocked", "half in the wall")
	assert_eq(b.can_place(&"crate", Vector2i(20, 21)).code, &"no_floor")
	assert_eq(b.can_place(&"crate", Vector2i(5, 5)).code, &"no_floor", "floating in the sky")


func test_bed_and_table_need_floor_under_every_tile() -> void:
	assert_true(b.can_place(&"bed", Vector2i(11, 22)).ok)
	assert_true(b.can_place(&"table", Vector2i(13, 22)).ok)
	g.apply_edit(Rect2i(12, 23, 1, 1), WorldGrid.Edit.DIG)
	assert_eq(b.can_place(&"bed", Vector2i(11, 22)).code, &"no_floor")
	assert_eq(b.can_place(&"table", Vector2i(12, 22)).code, &"no_floor")
	assert_true(b.can_place(&"table", Vector2i(13, 22)).ok)


func test_door_gap_rules() -> void:
	assert_true(b.can_place(&"door", Vector2i(15, 22)).ok, "3-tall corridor: ceiling above, floor below")
	assert_eq(b.can_place(&"door", Vector2i(15, 21)).code, &"blocked", "top tile would be in the ceiling")
	assert_eq(b.can_place(&"door", Vector2i(5, 9)).code, &"no_support", "open sky above")
	# 4-tall section: nothing solid right above the door.
	g.apply_edit(Rect2i(17, 19, 2, 1), WorldGrid.Edit.DIG)
	assert_eq(b.can_place(&"door", Vector2i(17, 22)).code, &"no_support")
	# A door needs a floor as well.
	g.apply_edit(Rect2i(12, 23, 1, 1), WorldGrid.Edit.DIG)
	assert_eq(b.can_place(&"door", Vector2i(12, 22)).code, &"no_floor")
	# Ceiling made of concrete counts as support.
	g.apply_edit(Rect2i(17, 19, 1, 1), WorldGrid.Edit.BUILD_WALL)
	assert_true(b.can_place(&"door", Vector2i(17, 22)).ok)


func test_place_and_query() -> void:
	watch_signals(b)
	watch_signals(g)
	var id := _place(&"door", Vector2i(15, 22))
	assert_eq(id, "bld:1")
	var fp := Rect2i(15, 20, 1, 3)
	assert_signal_emitted_with_parameters(b, "buildings_changed", [fp])
	assert_signal_emitted_with_parameters(g, "tiles_changed", [fp])
	assert_eq(b.building_at(Vector2i(15, 20)), id)
	assert_eq(b.building_at(Vector2i(15, 22)), id)
	assert_eq(b.building_at(Vector2i(16, 22)), "")
	assert_eq(b.building_at(Vector2i(-5, 22)), "")
	assert_true(b.is_door(Vector2i(15, 21)))
	assert_false(b.is_door(Vector2i(14, 21)))
	assert_eq(b.get_building(id), {"id": id, "key": &"door", "origin": Vector2i(15, 22),
			"materials": {&"rock": 50.0}})
	assert_eq(b.get_building("bld:99"), {})
	assert_true(g.has_building(Vector2i(15, 21)))
	assert_false(g.has_building(Vector2i(14, 21)))
	assert_true(g.is_passable(Vector2i(15, 21)), "doors do not block movement")
	var crate := _place(&"crate", Vector2i(20, 22), {&"dirt": 50})
	assert_eq(b.all_ids(), ["bld:1", "bld:2"] as Array[String])
	assert_false(b.is_door(Vector2i(20, 22)))
	assert_eq(b.room_tag_at(Vector2i(20, 22)), &"storage")
	assert_eq(b.get_building(crate)["materials"], {&"dirt": 50.0})
	# Occupied tiles block other buildings.
	assert_eq(b.can_place(&"crate", Vector2i(15, 22)).code, &"blocked")
	assert_eq(b.can_place(&"bed", Vector2i(19, 22)).code, &"blocked")


func test_place_rejects_bad_materials() -> void:
	var r := b.place(&"door", Vector2i(15, 22), {&"dirt": 50.0})
	assert_false(r.ok)
	assert_eq(r.code, &"invalid_materials")
	assert_eq(b.place(&"crate", Vector2i(20, 22), {&"rock": -1.0}).code, &"invalid_materials")
	assert_eq(b.place(&"crate", Vector2i(20, 22), {&"rock": "x"}).code, &"invalid_materials")
	assert_eq(b.place(&"crate", Vector2i(20, 21), ROCK).code, &"no_floor", "placement rules first")
	assert_eq(b.count(), 0)
	assert_eq(ids.peek_next(&"bld"), 1, "no id used by failed placements")


func test_occupancy_blocks_walls_and_ladders() -> void:
	_place(&"bed", Vector2i(11, 22))
	var r := g.apply_edit(Rect2i(10, 22, 4, 1), WorldGrid.Edit.BUILD_WALL)
	assert_true(r.ok)
	assert_eq(r.data["changed"], 2)
	assert_eq(g.get_tile(Vector2i(11, 22)), TileRegistry.AIR)
	assert_eq(g.get_tile(Vector2i(12, 22)), TileRegistry.AIR)
	assert_eq(g.get_tile(Vector2i(10, 22)), TileRegistry.CONCRETE)
	assert_eq(g.apply_edit(Rect2i(11, 22, 2, 1), WorldGrid.Edit.BUILD_WALL).code, &"nothing_to_change")
	assert_false(g.can_place_structure(Vector2i(12, 22), WorldGrid.Structure.LADDER))
	assert_eq(g.apply_structure(Vector2i(12, 22), WorldGrid.Structure.LADDER).code, &"occupied")
	assert_false(g.is_ladder(Vector2i(12, 22)))
	# Ladder tiles block buildings.
	g.apply_structure(Vector2i(18, 22), WorldGrid.Structure.LADDER)
	assert_eq(b.can_place(&"crate", Vector2i(18, 22)).code, &"blocked")


func test_remove_returns_materials() -> void:
	var id := _place(&"bed", Vector2i(11, 22), {&"dirt": 20.0, &"rock": 30.0})
	watch_signals(b)
	watch_signals(g)
	var r := b.remove(id)
	assert_true(r.ok, str(r))
	assert_eq(r.data["materials"], {&"dirt": 20.0, &"rock": 30.0})
	assert_eq(r.data["key"], &"bed")
	assert_eq(r.data["origin"], Vector2i(11, 22))
	assert_signal_emitted_with_parameters(b, "buildings_changed", [Rect2i(11, 22, 2, 1)])
	assert_signal_emitted_with_parameters(g, "tiles_changed", [Rect2i(11, 22, 2, 1)])
	assert_signal_not_emitted(b, "building_lost")
	assert_eq(b.building_at(Vector2i(11, 22)), "")
	assert_false(g.has_building(Vector2i(12, 22)))
	assert_eq(b.remove(id).code, &"unknown_building")
	assert_true(b.can_place(&"bed", Vector2i(11, 22)).ok)
	assert_eq(_place(&"bed", Vector2i(11, 22)), "bld:2", "ids are never reused")


func test_floor_loss_removes_building() -> void:
	var crate := _place(&"crate", Vector2i(20, 22))
	var bed := _place(&"bed", Vector2i(11, 22), {&"dirt": 50.0})
	watch_signals(b)
	g.apply_edit(Rect2i(30, 30, 2, 2), WorldGrid.Edit.DIG)
	assert_signal_not_emitted(b, "building_lost", "unrelated dig")
	g.apply_edit(Rect2i(20, 23, 1, 1), WorldGrid.Edit.DIG)
	assert_signal_emit_count(b, "building_lost", 1)
	assert_signal_emitted_with_parameters(b, "building_lost",
			[crate, &"crate", Vector2i(20, 22), {&"rock": 50.0}])
	assert_signal_emitted_with_parameters(b, "buildings_changed", [Rect2i(20, 22, 1, 1)])
	assert_eq(b.get_building(crate), {})
	assert_eq(b.building_at(Vector2i(20, 22)), "")
	# Losing only part of the floor is enough.
	g.apply_edit(Rect2i(12, 23, 1, 1), WorldGrid.Edit.DIG)
	assert_signal_emit_count(b, "building_lost", 2)
	assert_eq(b.get_building(bed), {})
	assert_eq(b.count(), 0)


func test_door_loses_top_support() -> void:
	var door := _place(&"door", Vector2i(15, 22))
	watch_signals(b)
	g.apply_edit(Rect2i(14, 19, 1, 1), WorldGrid.Edit.DIG)
	assert_signal_not_emitted(b, "building_lost", "ceiling next to the door")
	g.apply_edit(Rect2i(15, 19, 1, 1), WorldGrid.Edit.DIG)
	assert_signal_emitted_with_parameters(b, "building_lost",
			[door, &"door", Vector2i(15, 22), {&"rock": 50.0}])
	assert_false(b.is_door(Vector2i(15, 21)))


func test_deconstruct_wall_supporting_building() -> void:
	g.apply_edit(Rect2i(17, 23, 1, 1), WorldGrid.Edit.DIG)
	g.apply_edit(Rect2i(17, 23, 1, 1), WorldGrid.Edit.BUILD_WALL)
	var crate := _place(&"crate", Vector2i(17, 22))
	watch_signals(b)
	assert_true(g.apply_edit(Rect2i(17, 23, 1, 1), WorldGrid.Edit.DECONSTRUCT_WALL).ok)
	assert_signal_emit_count(b, "building_lost", 1)
	assert_eq(b.get_building(crate), {})


func test_snapshot_round_trip() -> void:
	var d := _place(&"door", Vector2i(15, 22))
	var c := _place(&"crate", Vector2i(20, 22), {&"dirt": 50.0})
	var bed := _place(&"bed", Vector2i(11, 22), {&"dirt": 10.0, &"rock": 40.0})
	b.remove(c)
	var snap := b.to_snapshot()
	var restored: Variant = bytes_to_var(var_to_bytes(snap))
	var other := Buildings.new(g, StableIdAllocator.new())
	assert_eq(other.load_snapshot(restored), 0)
	assert_eq(other.all_ids(), [d, bed] as Array[String])
	assert_eq(other.get_building(d), b.get_building(d))
	assert_eq(other.get_building(bed), b.get_building(bed))
	assert_true(other.is_door(Vector2i(15, 20)))
	assert_eq(other.building_at(Vector2i(12, 22)), bed)
	assert_eq(var_to_str(other.to_snapshot()), var_to_str(snap))
	# Loading replaces previous contents.
	assert_eq(other.load_snapshot({}), 0)
	assert_eq(other.count(), 0)
	assert_eq(other.building_at(Vector2i(12, 22)), "")


func test_snapshot_junk_is_dropped() -> void:
	var snap := {"buildings": [
		{"id": "bld:1", "key": "crate", "x": 20, "y": 22, "materials": {"rock": 50.0, "gold": 5.0, 7: 1.0}},
		"junk",
		42,
		{"id": "bld:1", "key": "crate", "x": 19, "y": 22, "materials": {}},   # duplicate id
		{"id": "npc:3", "key": "crate", "x": 18, "y": 22, "materials": {}},   # wrong category
		{"id": "bld:0", "key": "crate", "x": 18, "y": 22, "materials": {}},   # invalid id
		{"id": "bld:4", "key": "sofa", "x": 18, "y": 22, "materials": {}},    # unknown key
		{"id": "bld:5", "key": "crate", "x": 20, "y": 22, "materials": {}},   # overlaps bld:1
		{"id": "bld:6", "key": "crate", "x": 5, "y": 30, "materials": {}},    # inside dirt
		{"id": "bld:7", "key": "crate", "x": "18", "y": 22, "materials": {}}, # bad type
		{"id": "bld:8", "key": "crate", "x": 18, "y": 22, "materials": "x"},  # bad materials
		{"id": "bld:9", "key": "door", "x": 15, "y": 22},                    # ok, no materials
	]}
	assert_eq(b.load_snapshot(snap), 10)
	assert_eq(b.all_ids(), ["bld:1", "bld:9"] as Array[String])
	assert_eq(b.get_building("bld:1")["materials"], {&"rock": 50.0}, "unknown materials dropped")
	assert_eq(b.get_building("bld:9")["materials"], {})
	assert_eq(b.load_snapshot({"buildings": "nope"}), 0)
	assert_eq(b.count(), 0)
