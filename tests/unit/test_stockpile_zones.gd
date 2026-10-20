extends GutTest
## Grid from fs_util.make_grid: rows < 10 air, rows 10..62 dirt, row 63 bedrock.
## So valid stockpile tiles start out as row y = 9 only.

const FS := preload("res://tests/helpers/fs_util.gd")

var reg: TileRegistry
var g: WorldGrid
var inv: Inventory
var sp: StockpileZones


func before_all() -> void:
	reg = TileRegistry.load_default()


func before_each() -> void:
	g = FS.make_grid(reg)
	inv = Inventory.new(StableIdAllocator.new())
	sp = StockpileZones.new(g, inv)


func test_designate_only_floor_tiles() -> void:
	watch_signals(sp)
	var r := sp.designate(Rect2i(0, 7, 4, 5))  # rows 7..11
	assert_true(r.ok, str(r))
	assert_eq(r.data["added"], 4, "only row 9 (air above dirt)")
	assert_eq(r.data["skipped"], 16)
	assert_true(sp.is_stockpile(Vector2i(0, 9)))
	assert_false(sp.is_stockpile(Vector2i(0, 8)), "air above air")
	assert_false(sp.is_stockpile(Vector2i(0, 10)), "solid tile")
	assert_eq(sp.tiles(), [Vector2i(0, 9), Vector2i(1, 9), Vector2i(2, 9), Vector2i(3, 9)] as Array[Vector2i])
	assert_signal_emit_count(sp, "zones_changed", 1)


func test_designate_failures() -> void:
	assert_eq(sp.designate(Rect2i(-10, -10, 3, 3)).code, &"out_of_bounds")
	assert_eq(sp.designate(Rect2i(0, 0, 5, 5)).code, &"nothing_to_designate")
	assert_eq(sp.designate(Rect2i(0, 20, 5, 5)).code, &"nothing_to_designate")
	sp.designate(Rect2i(0, 9, 2, 1))
	assert_eq(sp.designate(Rect2i(0, 9, 2, 1)).code, &"nothing_to_designate", "already zoned")
	assert_eq(sp.count(), 2)
	assert_false(sp.is_stockpile(Vector2i(-1, 9)))
	assert_false(sp.is_stockpile(Vector2i(999, 9)))


func test_remove() -> void:
	sp.designate(Rect2i(0, 9, 6, 1))
	watch_signals(sp)
	var r := sp.remove(Rect2i(0, 0, 3, 20))
	assert_true(r.ok)
	assert_eq(r.data["removed"], 3)
	assert_eq(sp.count(), 3)
	assert_eq(sp.remove(Rect2i(0, 0, 3, 20)).code, &"nothing_to_remove")
	assert_signal_emit_count(sp, "zones_changed", 1)


func test_terrain_change_removes_invalid_tiles() -> void:
	sp.designate(Rect2i(0, 9, 5, 1))
	assert_true(sp.book(Vector2i(2, 9), 100.0, "job:1").ok)
	watch_signals(sp)
	# Dig the floor under (2,9): it is now air above air.
	assert_true(g.apply_edit(Rect2i(2, 10, 1, 1), WorldGrid.Edit.DIG).ok)
	assert_false(sp.is_stockpile(Vector2i(2, 9)))
	assert_true(sp.is_stockpile(Vector2i(1, 9)))
	assert_true(sp.is_stockpile(Vector2i(3, 9)))
	assert_eq(sp.count(), 4)
	assert_false(sp.is_stockpile(Vector2i(2, 10)), "new floor is not auto-zoned")
	assert_eq(sp.booked_tile("job:1"), StockpileZones.NO_TILE, "booking on removed tile dropped")
	assert_signal_emit_count(sp, "zones_changed", 1)
	# Building a wall on a zone tile also invalidates it.
	assert_true(g.apply_edit(Rect2i(0, 9, 1, 1), WorldGrid.Edit.BUILD_WALL).ok)
	assert_false(sp.is_stockpile(Vector2i(0, 9)))
	assert_eq(sp.count(), 3)


func test_unrelated_terrain_change_keeps_zones() -> void:
	sp.designate(Rect2i(0, 9, 5, 1))
	watch_signals(sp)
	g.apply_edit(Rect2i(0, 30, 5, 1), WorldGrid.Edit.DIG)
	assert_eq(sp.count(), 5)
	assert_signal_not_emitted(sp, "zones_changed")


func test_free_capacity_counts_ground_and_bookings() -> void:
	sp.designate(Rect2i(0, 9, 3, 1))
	var t := Vector2i(1, 9)
	assert_eq(sp.free_capacity(t), StockpileZones.TILE_CAPACITY_KG)
	assert_eq(sp.free_capacity(Vector2i(1, 8)), 0.0, "non-zone tile")
	inv.spawn_ground(&"dirt", 300.0, t)
	assert_eq(sp.free_capacity(t), StockpileZones.TILE_CAPACITY_KG - 300.0)
	assert_true(sp.book(t, 200.0, "job:1").ok)
	assert_eq(sp.free_capacity(t), StockpileZones.TILE_CAPACITY_KG - 500.0)
	assert_eq(sp.booked_kg(t), 200.0)
	assert_eq(sp.booked_tile("job:1"), t)
	sp.release("job:1")
	assert_eq(sp.free_capacity(t), StockpileZones.TILE_CAPACITY_KG - 300.0)
	assert_eq(sp.booked_kg(t), 0.0)
	sp.release("job:1")  # releasing twice is harmless
	sp.release("job:unknown")


func test_book_failures() -> void:
	sp.designate(Rect2i(0, 9, 3, 1))
	var t := Vector2i(0, 9)
	assert_eq(sp.book(Vector2i(0, 8), 10.0, "job:1").code, &"not_stockpile")
	assert_eq(sp.book(t, 0.0, "job:1").code, &"invalid_kg")
	assert_eq(sp.book(t, -1.0, "job:1").code, &"invalid_kg")
	assert_eq(sp.book(t, 10.0, "").code, &"invalid_job")
	assert_true(sp.book(t, 900.0, "job:1").ok)
	assert_eq(sp.book(t, 200.0, "job:2").code, &"no_capacity")
	assert_true(sp.book(t, 100.0, "job:2").ok, "exactly fills")
	assert_eq(sp.free_capacity(t), 0.0)


func test_rebooking_replaces() -> void:
	sp.designate(Rect2i(0, 9, 3, 1))
	var a := Vector2i(0, 9)
	var b := Vector2i(2, 9)
	assert_true(sp.book(a, 800.0, "job:1").ok)
	assert_true(sp.book(a, 1000.0, "job:1").ok, "same tile: own booking does not block")
	assert_eq(sp.booked_kg(a), 1000.0)
	assert_true(sp.book(b, 50.0, "job:1").ok)
	assert_eq(sp.booked_kg(a), 0.0, "old booking replaced")
	assert_eq(sp.booked_kg(b), 50.0)
	# A failed re-book keeps the previous booking.
	assert_true(sp.book(a, 1000.0, "job:2").ok)
	assert_eq(sp.book(a, 10.0, "job:1").code, &"no_capacity")
	assert_eq(sp.booked_tile("job:1"), b)
	assert_eq(sp.booked_kg(b), 50.0)


func test_find_drop_tile_nearest_and_ties() -> void:
	assert_eq(sp.find_drop_tile(10.0, Vector2i(5, 9)), Vector2i(-1, -1), "no zones")
	sp.designate(Rect2i(0, 9, 64, 1))
	assert_eq(sp.find_drop_tile(10.0, Vector2i(5, 9)), Vector2i(5, 9))
	assert_eq(sp.find_drop_tile(10.0, Vector2i(5, 3)), Vector2i(5, 9))
	# Tie between x=4 and x=6 -> smaller x.
	sp.remove(Rect2i(5, 9, 1, 1))
	assert_eq(sp.find_drop_tile(10.0, Vector2i(5, 9)), Vector2i(4, 9))
	# Full tile is skipped.
	inv.spawn_ground(&"rock", 995.0, Vector2i(4, 9))
	assert_eq(sp.find_drop_tile(10.0, Vector2i(5, 9)), Vector2i(6, 9))
	assert_eq(sp.find_drop_tile(5.0, Vector2i(5, 9)), Vector2i(4, 9), "5 kg still fits")
	sp.book(Vector2i(6, 9), 1000.0, "job:1")
	assert_eq(sp.find_drop_tile(10.0, Vector2i(5, 9)), Vector2i(3, 9))
	assert_eq(sp.find_drop_tile(2000.0, Vector2i(5, 9)), Vector2i(-1, -1), "too heavy for any tile")


func test_find_drop_tile_tie_prefers_smaller_y() -> void:
	# Dig a pit so a second floor row exists: (10,10) becomes air over dirt.
	g.apply_edit(Rect2i(10, 10, 1, 1), WorldGrid.Edit.DIG)
	sp.designate(Rect2i(0, 0, 64, 20))
	assert_true(sp.is_stockpile(Vector2i(10, 10)))
	assert_false(sp.is_stockpile(Vector2i(10, 9)))
	# From (10,11)... (10,10) d=1. From (11,10): (11,9) d=1 and (10,10) d=1 -> smaller y wins.
	assert_eq(sp.find_drop_tile(1.0, Vector2i(11, 10)), Vector2i(11, 9))


func test_find_drop_tile_is_deterministic_across_insertion_order() -> void:
	var sp2 := StockpileZones.new(g, inv)
	for x in [40, 3, 22, 9, 31]:
		sp.designate(Rect2i(x, 9, 1, 1))
	for x in [9, 31, 3, 40, 22]:
		sp2.designate(Rect2i(x, 9, 1, 1))
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 200:
		var near := Vector2i(rng.randi_range(-5, 70), rng.randi_range(0, 63))
		assert_eq(sp.find_drop_tile(1.0, near), sp2.find_drop_tile(1.0, near))
	assert_eq(sp.tiles(), sp2.tiles())


func test_is_stored() -> void:
	sp.designate(Rect2i(0, 9, 2, 1))
	var a := inv.spawn_ground(&"dirt", 10.0, Vector2i(0, 9))
	var b := inv.spawn_ground(&"dirt", 10.0, Vector2i(5, 9))
	assert_true(sp.is_stored(inv.get_item(a)))
	assert_false(sp.is_stored(inv.get_item(b)))
	assert_false(sp.is_stored(null))
	inv.pick_up(a, "npc:1")
	assert_false(sp.is_stored(inv.get_item(a)), "carried items are not stored")


func test_snapshot_round_trip() -> void:
	sp.designate(Rect2i(0, 9, 10, 1))
	sp.remove(Rect2i(4, 9, 1, 1))
	sp.book(Vector2i(2, 9), 120.0, "job:3")
	sp.book(Vector2i(2, 9), 30.0, "job:1")
	var snap := sp.to_snapshot()
	var sp2 := StockpileZones.new(g, Inventory.new(StableIdAllocator.new()))
	var dropped := sp2.load_snapshot(bytes_to_var(var_to_bytes(snap)))
	assert_eq(dropped, 0)
	assert_eq(sp2.tiles(), sp.tiles())
	assert_eq(sp2.booked_kg(Vector2i(2, 9)), 150.0)
	assert_eq(sp2.booked_tile("job:3"), Vector2i(2, 9))
	assert_eq(sp2.to_snapshot(), snap)


func test_load_snapshot_sanitizes() -> void:
	var junk := {
		"indices": PackedInt32Array([9 * 64 + 1, 9 * 64 + 2, -5, 99999999, 8 * 64 + 1, 20 * 64]),
		"bookings": [
			{"job_id": "job:1", "tile": Vector2i(1, 9), "kg": 50.0},
			{"job_id": "job:1", "tile": Vector2i(2, 9), "kg": 50.0},
			{"job_id": "job:2", "tile": Vector2i(8, 9), "kg": 50.0},
			{"job_id": "job:3", "tile": Vector2i(2, 9), "kg": -1.0},
			{"job_id": "", "tile": Vector2i(2, 9), "kg": 1.0},
			{"job_id": "job:4", "tile": "x", "kg": 1.0},
			{"job_id": "job:5", "tile": Vector2i(2, 9), "kg": 7},
			"junk",
			null,
		],
	}
	var dropped := sp.load_snapshot(junk)
	assert_eq(sp.tiles(), [Vector2i(1, 9), Vector2i(2, 9)] as Array[Vector2i])
	assert_eq(dropped, 4 + 7, "4 bad indices, 7 bad bookings")
	assert_eq(sp.booked_kg(Vector2i(1, 9)), 50.0)
	assert_eq(sp.booked_kg(Vector2i(2, 9)), 7.0)
	sp.load_snapshot({})
	assert_eq(sp.count(), 0)
	sp.load_snapshot({"indices": "nope", "bookings": 3})
	assert_eq(sp.count(), 0)
