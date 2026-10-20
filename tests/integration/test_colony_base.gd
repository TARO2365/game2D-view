extends GutTest
## M3 integration (acceptance: rooms respond to edits, structures consume
## hauled resources): a small underground base gets a crate, a bed, a table
## and a door built from hauled material, and a surface wall deconstructed.
## Invariants + conservation every 50 ticks; at the end the room behind the
## door is a bedroom.
##
## World 60x40: rows < 10 air, 10..38 dirt, 39 bedrock (surface feet row 9).
## A ladder shaft at x=2 leads to a corridor (rows 13..15, x 3..20); a
## 1-wide gap at x=21 (the door) opens into a room (x 22..30, rows 13..15).

const K := DesignationMap.Kind
const SIZE := Vector2i(60, 40)
const TICKS := 6000
const CHECK_EVERY := 50
const DOOR := Vector2i(21, 15)

var reg: TileRegistry


func before_all() -> void:
	reg = TileRegistry.load_default()


func _make_world() -> WorldGrid:
	var w := WorldGrid.new(SIZE.x, SIZE.y, reg)
	var tiles := PackedByteArray()
	tiles.resize(SIZE.x * SIZE.y)
	for y in SIZE.y:
		var id := TileRegistry.AIR
		if y == SIZE.y - 1:
			id = TileRegistry.BEDROCK
		elif y >= 10:
			id = TileRegistry.DIRT
		for x in SIZE.x:
			tiles[y * SIZE.x + x] = id
	w.tiles = tiles
	for x in SIZE.x:
		w.surface_y[x] = 10
	return w


func test_small_base_is_built() -> void:
	var g := _make_world()
	var ids := StableIdAllocator.new()
	var bld := Buildings.new(g, ids)
	var des := DesignationMap.new(g)
	var inv := Inventory.new(ids)
	var sp := StockpileZones.new(g, inv)
	var rooms := RoomMap.new(g, bld)
	var crates := CrateStorage.new(bld, inv)
	var orders := BuildOrders.new(g, bld, des, ids)
	var nav := NavGrid.new(g, 3)
	var jobs := JobManager.new(g, des, inv, sp, nav, ids, bld, crates, orders)
	var col := Colony.new(g, nav, jobs, ids, 7)

	# Carve the base (player digging is covered by M2 tests).
	g.apply_edit(Rect2i(2, 10, 1, 6), WorldGrid.Edit.DIG)      # shaft
	for y in range(10, 16):
		g.apply_structure(Vector2i(2, y), WorldGrid.Structure.LADDER)
	g.apply_edit(Rect2i(3, 13, 18, 3), WorldGrid.Edit.DIG)     # corridor x 3..20
	g.apply_edit(Rect2i(21, 13, 10, 3), WorldGrid.Edit.DIG)    # door gap + room x 22..30
	assert_true(rooms.room_at(Vector2i(26, 14)).is_empty(), "open to the corridor: no room yet")
	g.apply_edit(Rect2i(45, 9, 1, 1), WorldGrid.Edit.BUILD_WALL)  # a wall to take down

	sp.designate(Rect2i(8, 9, 4, 1))
	inv.spawn_ground(&"rock", 200.0, Vector2i(14, 9))
	inv.spawn_ground(&"dirt", 150.0, Vector2i(16, 9))
	assert_true(orders.order_building(&"door", DOOR).ok)
	assert_true(orders.order_building(&"bed", Vector2i(23, 15)).ok)
	assert_true(orders.order_building(&"table", Vector2i(26, 15)).ok)
	assert_true(orders.order_building(&"crate", Vector2i(29, 15)).ok)
	assert_true(des.designate(Rect2i(45, 9, 1, 1), K.DECONSTRUCT).ok)
	col.spawn_starting_npcs()
	assert_eq(col.count(), 3)

	var crate_had_items := false
	for tick in range(1, TICKS + 1):
		jobs.update(tick)
		col.update(tick)
		if tick % CHECK_EVERY == 0:
			var errs := jobs.check_invariants()
			errs.append_array(inv.check_conservation())
			if not errs.is_empty():
				fail_test("tick %d: %s" % [tick, errs])
				return
			for cid in crates.crate_ids():
				crate_had_items = crate_had_items or inv.crate_kg(cid) > 0.0
	assert_eq(orders.count(), 0, "every building order done")
	assert_eq(des.count(), 0, "the deconstruct order done")
	assert_eq(jobs.job_count(), 0)
	var keys := []
	for id in bld.all_ids():
		keys.append(String(bld.get_building(id)["key"]))
	keys.sort()
	assert_eq(keys, ["bed", "crate", "door", "table"])
	assert_eq(g.get_tile(Vector2i(45, 9)), TileRegistry.AIR)
	var room := rooms.room_at(Vector2i(26, 14))
	assert_false(room.is_empty(), "the door closes the room")
	assert_eq(room.get("type"), &"bedroom")
	assert_true(rooms.room_at(Vector2i(10, 14)).is_empty(), "the corridor is open to the sky")
	assert_true(crate_had_items, "haulers used the crate")
	# Everything left over is stored (crate or stockpile), nothing in hands.
	for it in inv.all_items():
		assert_true(it.holder == Inventory.Holder.CRATE or sp.is_stored(it),
				"%s %s stored (holder %d at %s)" % [it.id, it.material, it.holder, it.tile])
	var consumed := 0.0
	for m in inv.consumed_kg_by_material():
		consumed += float(inv.consumed_kg_by_material()[m])
	assert_almost_eq(consumed, 200.0, 0.001, "4 buildings x 50 kg")
	assert_almost_eq(float(inv.spawned_kg_by_material().get(&"rock", 0.0)), 250.0, 0.001,
			"200 placed + 50 refunded by the wall")
	assert_eq(jobs.check_invariants(), [] as Array[String])
	assert_eq(inv.check_conservation(), [] as Array[String])
	gut.p("base: rooms %d, searches %d" % [rooms.room_count(), nav.searches_total])
