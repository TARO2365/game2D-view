extends GutTest
## M3 Colony: BuildOrders, building jobs, deconstruct jobs, crate hauling,
## material from crates, building loss, cancel in every phase.
## Grid 40x30 from fs_util.make_grid: rows < 10 air, 10..28 dirt, 29 bedrock
## (surface feet row 9).

const FS := preload("res://tests/helpers/fs_util.gd")
const K := DesignationMap.Kind

var reg: TileRegistry
var g: WorldGrid
var ids: StableIdAllocator
var bld: Buildings
var des: DesignationMap
var inv: Inventory
var sp: StockpileZones
var rooms: RoomMap
var crates: CrateStorage
var orders: BuildOrders
var nav: NavGrid
var jobs: JobManager
var col: Colony
var t := 0


func before_all() -> void:
	reg = TileRegistry.load_default()


func before_each() -> void:
	g = FS.make_grid(reg, Vector2i(40, 30))
	ids = StableIdAllocator.new()
	bld = Buildings.new(g, ids)
	des = DesignationMap.new(g)
	inv = Inventory.new(ids)
	sp = StockpileZones.new(g, inv)
	rooms = RoomMap.new(g, bld)
	crates = CrateStorage.new(bld, inv)
	orders = BuildOrders.new(g, bld, des, ids)
	nav = NavGrid.new(g, 3)
	jobs = JobManager.new(g, des, inv, sp, nav, ids, bld, crates, orders)
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


func _kg(mat: StringName) -> float:
	return float(inv.total_kg_by_material().get(mat, 0.0))


## Puts kg of material into crate cid (test setup through Inventory).
func _fill_crate(cid: String, mat: StringName, kg: float) -> void:
	var iid := inv.spawn_ground(mat, kg, Vector2i(0, 9))
	assert_true(inv.pick_up(iid, "npc:999", kg).ok)
	assert_true(inv.store_in_crate("npc:999", cid).ok)


func _assert_clean() -> void:
	assert_eq(jobs.check_invariants(), [] as Array[String])
	assert_eq(inv.check_conservation(), [] as Array[String])
	for j in jobs.all_jobs():
		assert_eq(j.worker_id, "", "%s has no worker" % j.id)
		assert_eq(j.item_id, "", "%s reserves nothing" % j.id)
		assert_eq(j.carried_id, "")
	for n in col.all_npcs():
		assert_eq(n.job_id, "")
		assert_null(inv.carried_by(n.id))
	assert_eq(crates.to_snapshot()["bookings"].size(), 0)
	for it in inv.all_items():
		assert_true(it.holder == Inventory.Holder.GROUND or it.holder == Inventory.Holder.CRATE,
				"%s is on the ground or in a crate" % it.id)


# --- BuildOrders ----------------------------------------------------------

func test_order_validation_and_queries() -> void:
	watch_signals(orders)
	var r := orders.order_building(&"bed", Vector2i(10, 9), 7)
	assert_true(r.ok, str(r))
	var oid: String = r.data["id"]
	assert_true(oid.begins_with("bord:"))
	assert_signal_emit_count(orders, "orders_changed", 1)
	assert_eq(orders.order_at(Vector2i(11, 9))["id"], oid, "2-wide footprint")
	assert_eq(orders.order_at(Vector2i(10, 9))["priority"], 7)
	assert_eq(orders.order_building(&"table", Vector2i(11, 9)).code, &"overlaps_order")
	assert_eq(orders.order_building(&"bed", Vector2i(10, 5)).code, &"no_floor")
	assert_eq(orders.order_building(&"bed", Vector2i(10, 12)).code, &"blocked")
	assert_eq(orders.order_building(&"sofa", Vector2i(20, 9)).code, &"unknown_key")
	assert_eq(orders.order_building(&"bed", Vector2i(20, 9), 0).code, &"invalid_priority")
	des.designate(Rect2i(30, 9, 1, 1), K.BUILD_LADDER)
	assert_eq(orders.order_building(&"crate", Vector2i(30, 9)).code, &"overlaps_designation")
	assert_eq(orders.orders().size(), 1)
	assert_eq(jobs.job_count(), 2, "building job + ladder job")
	var bj := jobs.job_at(Vector2i(11, 9))
	assert_eq(bj.kind, Job.KIND_BUILDING)
	assert_eq(bj.priority, 7)
	assert_eq(jobs.describe_job(bj.id), "Build bed (10, 9)")
	assert_true(orders.set_priority(Rect2i(10, 9, 1, 1), 9).ok)
	assert_eq(bj.priority, 9)
	assert_true(orders.cancel_at(Rect2i(11, 9, 1, 1)).ok)
	assert_eq(orders.count(), 0)
	assert_null(jobs.get_job(bj.id), "cancelling the order removes its job")
	assert_eq(orders.cancel_at(Rect2i(11, 9, 1, 1)).code, &"nothing_to_cancel")


func test_order_invalidated_by_terrain_and_designations() -> void:
	orders.order_building(&"crate", Vector2i(10, 9))
	orders.order_building(&"crate", Vector2i(20, 9))
	assert_eq(jobs.job_count(), 2)
	g.apply_edit(Rect2i(10, 10, 1, 1), WorldGrid.Edit.DIG)  # floor gone
	assert_eq(orders.count(), 1, "order without a floor is removed")
	des.designate(Rect2i(20, 9, 1, 1), K.BUILD_WALL)  # newest order wins
	assert_eq(orders.count(), 0)
	assert_eq(jobs.job_count(), 1, "only the wall job is left")
	assert_eq(jobs.check_invariants(), [] as Array[String])


func test_order_snapshot_round_trip() -> void:
	orders.order_building(&"bed", Vector2i(10, 9), 3)
	orders.order_building(&"door", Vector2i(30, 9))  # no support yet -> refused
	g.apply_edit(Rect2i(30, 6, 1, 1), WorldGrid.Edit.BUILD_WALL)
	assert_true(orders.order_building(&"door", Vector2i(30, 9)).ok)
	var s: Dictionary = bytes_to_var(var_to_bytes(orders.to_snapshot()))
	(s["orders"] as Array).append({"id": "bord:99", "key": "bed", "x": 10, "y": 9, "priority": 5})
	(s["orders"] as Array).append("junk")
	var o2 := BuildOrders.new(g, bld, des, StableIdAllocator.new())
	assert_eq(o2.load_snapshot(s), 2, "overlapping copy + junk dropped")
	assert_eq(o2.orders(), orders.orders())


# --- Building jobs ----------------------------------------------------------

func test_build_every_building() -> void:
	col.spawn_npc(Vector2i(5, 9))
	col.spawn_npc(Vector2i(6, 9))
	inv.spawn_ground(&"rock", 200.0, Vector2i(2, 9))
	inv.spawn_ground(&"dirt", 100.0, Vector2i(3, 9))
	g.apply_edit(Rect2i(30, 6, 1, 1), WorldGrid.Edit.BUILD_WALL)  # door support
	for o: Array in [[&"crate", Vector2i(12, 9)], [&"bed", Vector2i(15, 9)],
			[&"table", Vector2i(19, 9)], [&"door", Vector2i(30, 9)]]:
		assert_true(orders.order_building(o[0], o[1]).ok, "order %s" % o[0])
	assert_true(_run(3000, func() -> bool: return bld.count() == 4 and orders.count() == 0))
	var keys := {}
	for id in bld.all_ids():
		var b := bld.get_building(id)
		keys[b["key"]] = b
		var total := 0.0
		for m in b["materials"]:
			total += float(b["materials"][m])
		assert_almost_eq(total, bld.def(b["key"]).kg, 0.001, "%s built from its recipe kg" % b["key"])
	assert_eq(keys.size(), 4)
	assert_true(bld.is_door(Vector2i(30, 8)))
	assert_eq(bld.building_at(Vector2i(16, 9)), keys[&"bed"]["id"])
	var consumed := 0.0
	for m in inv.consumed_kg_by_material():
		consumed += float(inv.consumed_kg_by_material()[m])
	assert_almost_eq(consumed, 200.0, 0.001, "4 x 50 kg consumed")


func test_door_not_completed_on_an_npc() -> void:
	var builder := col.spawn_npc(Vector2i(5, 9))
	var idler := col.spawn_npc(Vector2i(25, 9))  # stands in the doorway
	for w in Npc.WORK_KEYS:
		col.set_work_enabled(idler.id, w, false)
	inv.spawn_ground(&"rock", 50.0, Vector2i(2, 9))
	g.apply_edit(Rect2i(25, 6, 1, 1), WorldGrid.Edit.BUILD_WALL)
	assert_true(orders.order_building(&"door", Vector2i(25, 9)).ok)
	var saw_blocked := [false]
	var occupied_at_completion := [false]
	assert_true(_run(1500, func() -> bool:
		var j := jobs.job_at(Vector2i(25, 8))
		if j != null and j.wait_reason == JobManager.REASON_BLOCKED:
			saw_blocked[0] = true
		if bld.count() == 1:
			for y in range(7, 10):
				if col.npc_at(Vector2i(25, y)) != null:
					occupied_at_completion[0] = true
			return true
		return false))
	assert_true(saw_blocked[0], "door waited while the NPC stood in it")
	assert_false(occupied_at_completion[0], "no NPC body in the doorway when it was completed")
	assert_true(bld.is_door(Vector2i(25, 9)))
	assert_ne(idler.tile.x, 25, "the idle NPC stepped aside")
	assert_eq(builder.job_id, "")


func test_material_taken_from_crate() -> void:
	var cid: String = bld.place(&"crate", Vector2i(8, 9), {&"dirt": 50.0}).data["id"]
	_fill_crate(cid, &"rock", 80.0)
	col.spawn_npc(Vector2i(5, 9))
	des.designate(Rect2i(20, 9, 1, 1), K.BUILD_WALL)
	assert_true(_run(800, func() -> bool: return g.get_tile(Vector2i(20, 9)) == TileRegistry.CONCRETE))
	assert_almost_eq(inv.crate_kg(cid), 30.0, 0.001, "50 kg taken out, the rest stays in the crate")
	assert_almost_eq(float(inv.consumed_kg_by_material().get(&"rock", 0.0)), 50.0, 0.001)


# --- Deconstruction ----------------------------------------------------------

func test_deconstruct_wall() -> void:
	col.spawn_npc(Vector2i(5, 9))
	g.apply_edit(Rect2i(20, 9, 1, 1), WorldGrid.Edit.BUILD_WALL)
	assert_true(des.designate(Rect2i(20, 9, 1, 1), K.DECONSTRUCT).ok)
	var j := jobs.job_at(Vector2i(20, 9))
	assert_eq(j.kind, Job.KIND_DECONSTRUCT, "kind 4 is not a build job")
	assert_eq(jobs.describe_job(j.id), "Deconstruct wall (20, 9)")
	assert_true(_run(500, func() -> bool: return g.get_tile(Vector2i(20, 9)) == TileRegistry.AIR))
	_run(2)
	assert_eq(jobs.job_count(), 0)
	assert_eq(des.count(), 0)
	assert_almost_eq(inv.ground_kg_at(Vector2i(20, 9)), 50.0, 0.001, "wall recipe rock refunded")
	assert_eq(inv.all_items()[0].material, &"rock")


func test_deconstruct_ladder_drops_with_gravity() -> void:
	col.spawn_npc(Vector2i(5, 9))
	g.apply_edit(Rect2i(20, 10, 1, 3), WorldGrid.Edit.DIG)
	for y in range(10, 13):
		g.apply_structure(Vector2i(20, y), WorldGrid.Structure.LADDER)
	assert_true(des.designate(Rect2i(20, 10, 1, 1), K.DECONSTRUCT).ok)  # top ladder tile
	assert_true(_run(500, func() -> bool: return not g.is_ladder(Vector2i(20, 10))))
	assert_true(g.is_ladder(Vector2i(20, 11)))
	var it: ItemStack = inv.all_items()[0]
	assert_eq(it.material, &"dirt")
	assert_almost_eq(it.kg, 25.0, 0.001)
	assert_eq(it.tile, Vector2i(20, 12), "fell down the ladders to the shaft floor")


func test_deconstruct_furniture_one_job_per_building() -> void:
	col.spawn_npc(Vector2i(5, 9))
	var id: String = bld.place(&"bed", Vector2i(14, 9), {&"rock": 30.0, &"dirt": 20.0}).data["id"]
	assert_true(des.designate(Rect2i(13, 9, 4, 1), K.DECONSTRUCT).ok)
	assert_eq(des.count(), 2, "both bed tiles")
	assert_eq(jobs.job_count(), 1, "one job for the whole bed")
	var j := jobs.job_at(Vector2i(15, 9))
	assert_eq(j, jobs.job_at(Vector2i(14, 9)))
	assert_eq(j.order_id, id)
	des.cancel(Rect2i(14, 9, 1, 1))
	assert_eq(jobs.job_count(), 1, "the other tile keeps the job")
	assert_eq(jobs.check_invariants(), [] as Array[String])
	assert_true(_run(500, func() -> bool: return bld.count() == 0))
	_run(2)
	assert_almost_eq(_kg(&"rock"), 30.0, 0.001, "100 % refund")
	assert_almost_eq(_kg(&"dirt"), 20.0, 0.001)
	assert_eq(jobs.job_count(), 0)
	assert_eq(des.count(), 0)


func test_deconstruct_crate_with_contents() -> void:
	col.spawn_npc(Vector2i(5, 9))
	var cid: String = bld.place(&"crate", Vector2i(12, 9), {&"dirt": 50.0}).data["id"]
	_fill_crate(cid, &"rock", 300.0)
	assert_true(des.designate(Rect2i(12, 9, 1, 1), K.DECONSTRUCT).ok)
	assert_true(_run(500, func() -> bool: return bld.count() == 0))
	assert_almost_eq(inv.ground_kg_at(Vector2i(12, 9)), 350.0, 0.001, "contents + crate material")
	assert_almost_eq(_kg(&"rock"), 300.0, 0.001)
	assert_almost_eq(_kg(&"dirt"), 50.0, 0.001)
	assert_eq(inv.crate_items(cid).size(), 0)


func test_building_lost_when_floor_is_dug() -> void:
	var bed: String = bld.place(&"bed", Vector2i(14, 9), {&"rock": 50.0}).data["id"]
	var cid: String = bld.place(&"crate", Vector2i(20, 9), {&"dirt": 50.0}).data["id"]
	_fill_crate(cid, &"dirt", 100.0)
	assert_true(des.designate(Rect2i(14, 9, 1, 1), K.DECONSTRUCT).ok)  # a job on the lost bed
	assert_eq(jobs.job_count(), 1)
	g.apply_edit(Rect2i(14, 10, 1, 1), WorldGrid.Edit.DIG)
	g.apply_edit(Rect2i(20, 10, 1, 1), WorldGrid.Edit.DIG)
	assert_eq(bld.count(), 0, "both lost their floor")
	assert_eq(jobs.job_count(), 0, "the deconstruct job of the lost bed is gone")
	assert_almost_eq(inv.ground_kg_at(Vector2i(14, 10)), 50.0, 0.001, "bed material fell into the hole")
	assert_almost_eq(inv.ground_kg_at(Vector2i(20, 10)), 150.0, 0.001, "crate material + contents")
	assert_eq(inv.crate_items(cid).size(), 0)
	assert_eq(jobs.check_invariants(), [] as Array[String])
	assert_eq(inv.check_conservation(), [] as Array[String])
	assert_ne(bed, "")


# --- Crate hauling ------------------------------------------------------------

func test_haul_prefers_crate_then_filter_then_capacity() -> void:
	for i in 3:
		col.spawn_npc(Vector2i(4 + i, 9))
	sp.designate(Rect2i(30, 9, 3, 1))
	var cid: String = bld.place(&"crate", Vector2i(10, 9), {&"dirt": 50.0}).data["id"]
	var d1 := inv.spawn_ground(&"dirt", 50.0, Vector2i(20, 9))  # zone is nearer, crate preferred
	assert_true(_run(600, func() -> bool: return inv.get_item(d1).holder == Inventory.Holder.CRATE))
	assert_true(crates.is_stored(inv.get_item(d1)))
	_run(20)
	assert_eq(jobs.job_count(), 0, "items in crates are never re-hauled")
	# Filter: rock only -> dirt goes to the stockpile.
	crates.set_filter(cid, [&"rock"] as Array[StringName])
	var d2 := inv.spawn_ground(&"dirt", 30.0, Vector2i(20, 9))
	assert_true(_run(600, func() -> bool: return sp.is_stored(inv.get_item(d2))))
	# Capacity: 2000 kg minus the 50 kg dirt already inside (filter does not evict).
	for i in 11:
		inv.spawn_ground(&"rock", 200.0, Vector2i(18 + i % 3, 9))
	assert_true(_run(4000, func() -> bool:
		for it in inv.all_items():
			if it.holder == Inventory.Holder.GROUND and not sp.is_stored(it):
				return false
			if it.holder == Inventory.Holder.NPC:
				return false
		return true))
	assert_lte(inv.crate_kg(cid), 2000.0 + 0.001, "never over capacity")
	assert_gt(inv.crate_kg(cid), 1800.0)
	assert_eq(crates.to_snapshot()["bookings"].size(), 0)


func test_crate_removed_mid_haul_rebooks() -> void:
	var n := col.spawn_npc(Vector2i(5, 9))
	sp.designate(Rect2i(30, 9, 1, 1))
	var cid: String = bld.place(&"crate", Vector2i(10, 9), {&"dirt": 50.0}).data["id"]
	var d := inv.spawn_ground(&"rock", 40.0, Vector2i(3, 9))
	assert_true(_run(300, func() -> bool: return inv.carried_by(n.id) != null))
	bld.remove(cid)  # (refund not dropped here: test only checks the haul)
	assert_true(_run(600, func() -> bool: return sp.is_stored(inv.get_item(d))))


# --- Cancel in every phase ------------------------------------------------------

func _table_setup() -> String:
	inv.spawn_ground(&"rock", 25.0, Vector2i(2, 9))
	inv.spawn_ground(&"rock", 25.0, Vector2i(3, 9))
	assert_true(orders.order_building(&"table", Vector2i(16, 9)).ok)
	return jobs.job_at(Vector2i(16, 9)).id


func test_cancel_building_while_fetching() -> void:
	col.spawn_npc(Vector2i(8, 9))
	var jid := _table_setup()
	assert_true(_run(30, func() -> bool:
		var j := jobs.get_job(jid)
		return j != null and j.phase == Job.PHASE_FETCH and not j.item_id.is_empty()))
	orders.cancel_at(Rect2i(16, 9, 1, 1))
	_assert_clean()
	assert_almost_eq(_kg(&"rock"), 50.0, 0.001)


func test_cancel_building_while_carrying() -> void:
	var n := col.spawn_npc(Vector2i(8, 9))
	_table_setup()
	assert_true(_run(200, func() -> bool: return inv.carried_by(n.id) != null and n.is_moving()))
	orders.cancel_at(Rect2i(16, 9, 1, 1))
	_assert_clean()
	assert_almost_eq(_kg(&"rock"), 50.0, 0.001)


func test_cancel_building_partially_delivered() -> void:
	var n := col.spawn_npc(Vector2i(8, 9))
	var jid := _table_setup()
	assert_true(_run(400, func() -> bool: return inv.site_kg(jid) > 0.0 and inv.carried_by(n.id) == null))
	orders.cancel_at(Rect2i(17, 9, 1, 1))
	assert_almost_eq(inv.site_kg(jid), 0.0, 0.001)
	assert_almost_eq(inv.ground_kg_at(Vector2i(16, 9)), 25.0, 0.001, "site material back at the origin")
	_assert_clean()


func test_cancel_building_while_working() -> void:
	var n := col.spawn_npc(Vector2i(8, 9))
	_table_setup()
	assert_true(_run(600, func() -> bool: return n.state == &"working"))
	orders.cancel_at(Rect2i(16, 9, 1, 1))
	_assert_clean()
	assert_eq(bld.count(), 0)
	assert_almost_eq(_kg(&"rock"), 50.0, 0.001)


func test_cancel_deconstruct_while_working() -> void:
	var n := col.spawn_npc(Vector2i(8, 9))
	var id: String = bld.place(&"table", Vector2i(16, 9), {&"rock": 50.0}).data["id"]
	des.designate(Rect2i(16, 9, 2, 1), K.DECONSTRUCT)
	assert_true(_run(300, func() -> bool: return n.state == &"working"))
	des.cancel(Rect2i(16, 9, 2, 1))
	_assert_clean()
	assert_eq(jobs.job_count(), 0)
	assert_false(bld.get_building(id).is_empty(), "table stays")


func test_stop_and_move_during_deconstruct() -> void:
	var n := col.spawn_npc(Vector2i(8, 9))
	g.apply_edit(Rect2i(20, 9, 1, 1), WorldGrid.Edit.BUILD_WALL)
	des.designate(Rect2i(20, 9, 1, 1), K.DECONSTRUCT)
	assert_true(_run(300, func() -> bool: return n.state == &"working"))
	var j := jobs.job_at(Vector2i(20, 9))
	var done := j.work_ticks
	assert_true(col.command_stop(n.id).ok)
	assert_eq(j.worker_id, "")
	assert_eq(j.work_ticks, done, "progress kept")
	assert_true(_run(600, func() -> bool: return g.get_tile(Vector2i(20, 9)) == TileRegistry.AIR))
