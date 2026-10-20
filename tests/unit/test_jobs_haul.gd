extends GutTest
## Haul jobs: loose items are carried to stockpiles (never teleported),
## capacity bookings, splitting heavy stacks, lost bookings.
## Grid 40x30 from fs_util.make_grid: rows < 10 air, 10..28 dirt, 29 bedrock.

const FS := preload("res://tests/helpers/fs_util.gd")

var reg: TileRegistry
var g: WorldGrid
var ids: StableIdAllocator
var des: DesignationMap
var inv: Inventory
var sp: StockpileZones
var nav: NavGrid
var jobs: JobManager
var col: Colony
var t := 0


func before_all() -> void:
	reg = TileRegistry.load_default()


func before_each() -> void:
	g = FS.make_grid(reg, Vector2i(40, 30))
	ids = StableIdAllocator.new()
	des = DesignationMap.new(g)
	inv = Inventory.new(ids)
	sp = StockpileZones.new(g, inv)
	nav = NavGrid.new(g, 3)
	jobs = JobManager.new(g, des, inv, sp, nav, ids)
	col = Colony.new(g, nav, jobs, ids, 42)
	t = 0


func _run(max_ticks: int, cond: Callable = Callable()) -> bool:
	for i in max_ticks:
		t += 1
		jobs.update(t)
		col.update(t)
		var errs := jobs.check_invariants()
		errs.append_array(inv.check_conservation())
		if not errs.is_empty():
			fail_test("tick %d: %s" % [t, errs])
			return false
		if cond.is_valid() and cond.call():
			return true
	return false


func _all_stored() -> bool:
	for it in inv.all_items():
		if not sp.is_stored(it):
			return false
	return true


func test_haul_flow() -> void:
	var n := col.spawn_npc(Vector2i(5, 9))
	sp.designate(Rect2i(20, 9, 3, 1))
	var id := inv.spawn_ground(&"dirt", 50.0, Vector2i(3, 9))
	_run(5)
	assert_eq(jobs.job_count(), 1, "haul job created at NORMAL cadence")
	assert_almost_eq(sp.booked_kg(Vector2i(20, 9)), 50.0, 0.001, "capacity booked")
	var seen_carrying := [false]
	var positions := {}
	assert_true(_run(300, func() -> bool:
		var c := inv.carried_by(n.id)
		if c != null:
			seen_carrying[0] = true
			positions[n.tile] = true
			if n.is_moving():
				assert_eq(n.state, &"carrying")
		return _all_stored()))
	assert_true(seen_carrying[0], "physically carried")
	assert_gt(positions.size(), 5, "walked with it")
	assert_eq(inv.get_item(id).tile, Vector2i(20, 9))
	assert_almost_eq(sp.booked_kg(Vector2i(20, 9)), 0.0, 0.001, "booking released")
	assert_eq(jobs.job_count(), 0)


func test_heavy_stack_split_over_trips() -> void:
	col.spawn_npc(Vector2i(5, 9))
	sp.designate(Rect2i(20, 9, 3, 1))
	inv.spawn_ground(&"dirt", 300.0, Vector2i(3, 9))
	assert_true(_run(800, _all_stored))
	assert_eq(inv.all_items().size(), 2, "200 + 100")
	var total := 0.0
	for it in inv.all_items():
		total += it.kg
		assert_lte(it.kg, Inventory.CARRY_CAPACITY_KG + 0.001)
	assert_almost_eq(total, 300.0, 0.001)


func test_no_stockpile_no_haul() -> void:
	col.spawn_npc(Vector2i(5, 9))
	inv.spawn_ground(&"dirt", 50.0, Vector2i(3, 9))
	_run(60)
	assert_eq(jobs.job_count(), 0)
	sp.designate(Rect2i(20, 9, 1, 1))
	assert_true(_run(300, _all_stored), "zone creation re-checks waiting items")


func test_stored_items_stay() -> void:
	col.spawn_npc(Vector2i(5, 9))
	sp.designate(Rect2i(20, 9, 3, 1))
	inv.spawn_ground(&"dirt", 50.0, Vector2i(21, 9))
	_run(30)
	assert_eq(jobs.job_count(), 0)
	assert_eq(inv.all_items()[0].tile, Vector2i(21, 9))


func test_full_stockpile_not_overbooked() -> void:
	for i in 3:
		col.spawn_npc(Vector2i(4 + i, 9))
	sp.designate(Rect2i(20, 9, 1, 1))  # 1000 kg
	for i in 6:
		inv.spawn_ground(&"dirt", 200.0, Vector2i(2 + i, 9))
	assert_true(_run(1500, func() -> bool: return inv.ground_kg_at(Vector2i(20, 9)) >= 999.0))
	_run(100)
	assert_almost_eq(inv.ground_kg_at(Vector2i(20, 9)), 1000.0, 0.001)
	assert_eq(jobs.job_count(), 0)
	assert_almost_eq(sp.booked_kg(Vector2i(20, 9)), 0.0, 0.001)


func test_lost_booking_rebooks_elsewhere() -> void:
	var n := col.spawn_npc(Vector2i(5, 9))
	sp.designate(Rect2i(20, 9, 1, 1))
	sp.designate(Rect2i(30, 9, 1, 1))
	inv.spawn_ground(&"dirt", 50.0, Vector2i(3, 9))
	assert_true(_run(200, func() -> bool: return inv.carried_by(n.id) != null))
	var job_id := n.job_id
	assert_eq(sp.booked_tile(job_id), Vector2i(20, 9))
	sp.remove(Rect2i(20, 9, 1, 1))
	assert_eq(sp.booked_tile(job_id), StockpileZones.NO_TILE)
	assert_true(_run(400, _all_stored))
	assert_eq(inv.all_items()[0].tile, Vector2i(30, 9))


func test_lost_booking_without_space_drops_in_place() -> void:
	var n := col.spawn_npc(Vector2i(5, 9))
	sp.designate(Rect2i(20, 9, 1, 1))
	inv.spawn_ground(&"dirt", 50.0, Vector2i(3, 9))
	assert_true(_run(200, func() -> bool: return inv.carried_by(n.id) != null and n.is_moving()))
	sp.remove(Rect2i(20, 9, 1, 1))
	assert_true(_run(50, func() -> bool: return inv.carried_by(n.id) == null))
	assert_eq(jobs.job_count(), 0)
	assert_eq(inv.all_items()[0].holder, Inventory.Holder.GROUND)
	assert_true(nav.can_stand(inv.all_items()[0].tile), "dropped where the NPC stood")


func test_item_gravity_after_floor_dug() -> void:
	inv.spawn_ground(&"dirt", 50.0, Vector2i(5, 9))
	var other := inv.spawn_ground(&"dirt", 10.0, Vector2i(9, 9))
	g.apply_edit(Rect2i(5, 10, 1, 3), WorldGrid.Edit.DIG)
	assert_eq(inv.all_items()[0].tile, Vector2i(5, 12), "fell to the new floor")
	assert_eq(inv.get_item(other).tile, Vector2i(9, 9), "items outside the changed columns stay")
	assert_eq(inv.check_conservation(), [] as Array[String])


func test_reserved_item_falls_and_is_still_hauled() -> void:
	var n := col.spawn_npc(Vector2i(30, 9))
	sp.designate(Rect2i(33, 9, 2, 1))
	var id := inv.spawn_ground(&"dirt", 50.0, Vector2i(5, 9))
	assert_true(_run(20, func() -> bool: return n.job_id != "" and n.is_moving()))
	var job := jobs.get_job(n.job_id)
	assert_eq(job.item_id, id)
	# Ladder shaft under the stack so it stays reachable after falling.
	g.apply_edit(Rect2i(5, 10, 1, 3), WorldGrid.Edit.DIG)
	for y in range(10, 13):
		g.apply_structure(Vector2i(5, y), WorldGrid.Structure.LADDER)
	assert_eq(inv.get_item(id).tile, Vector2i(5, 12))
	assert_eq(job.item_id, id, "reservation kept")
	assert_true(_run(800, _all_stored))
	assert_eq(jobs.job_count(), 0)


func test_unreachable_stockpile_not_retried_by_same_npc() -> void:
	g.apply_edit(Rect2i(30, 6, 1, 4), WorldGrid.Edit.BUILD_WALL)  # pillar
	sp.designate(Rect2i(30, 5, 1, 1))
	inv.spawn_ground(&"dirt", 50.0, Vector2i(10, 9))
	var n := col.spawn_npc(Vector2i(5, 9))
	var pickups := [0]
	inv.items_changed.connect(func(iid: String) -> void:
		var it := inv.get_item(iid)
		if it != null and it.holder == Inventory.Holder.NPC:
			pickups[0] += 1)
	_run(1500)
	assert_lte(pickups[0], 1)
	assert_eq(n.state, &"idle")


func test_haul_rebooks_to_reachable_zone_tile() -> void:
	g.apply_edit(Rect2i(30, 6, 1, 4), WorldGrid.Edit.BUILD_WALL)  # pillar
	sp.designate(Rect2i(30, 5, 1, 1))   # nearest zone tile, on the pillar: unreachable
	sp.designate(Rect2i(14, 9, 1, 1))   # farther, reachable
	var id := inv.spawn_ground(&"dirt", 50.0, Vector2i(25, 9))
	col.spawn_npc(Vector2i(5, 9))
	var pickups := [0]
	inv.items_changed.connect(func(iid: String) -> void:
		var it := inv.get_item(iid)
		if it != null and it.holder == Inventory.Holder.NPC:
			pickups[0] += 1)
	assert_true(_run(3000, func() -> bool:
		var st := inv.get_item(id)
		return st.tile == Vector2i(14, 9) and st.holder == Inventory.Holder.GROUND))
	assert_lte(pickups[0], 2, "at most one wasted trip to the pillar")
	assert_eq(sp.to_snapshot()["bookings"].size(), 0)


func test_stack_dropped_on_ladder_lands_on_floor() -> void:
	g.apply_edit(Rect2i(20, 10, 1, 8), WorldGrid.Edit.DIG)  # shaft rows 10..17, floor 18
	for y in range(10, 18):
		g.apply_structure(Vector2i(20, y), WorldGrid.Structure.LADDER)
	sp.designate(Rect2i(2, 9, 1, 1))
	inv.spawn_ground(&"dirt", 50.0, Vector2i(20, 17))
	var n := col.spawn_npc(Vector2i(10, 9))
	assert_true(_run(1500, func() -> bool:
		return inv.carried_by(n.id) != null and n.tile.x == 20 and n.tile.y < 16 and n.tile.y > 10))
	col.command_stop(n.id)
	var it: ItemStack = inv.all_items()[0]
	assert_eq(it.holder, Inventory.Holder.GROUND)
	assert_eq(it.tile, Vector2i(20, 17), "fell down the shaft to its floor")
