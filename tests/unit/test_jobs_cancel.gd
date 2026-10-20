extends GutTest
## Cancelling an order (or stopping the worker) during every job phase leaves
## no reservation behind and conserves every kg.
## Grid 40x30 from fs_util.make_grid: rows < 10 air, 10..28 dirt, 29 bedrock.

const FS := preload("res://tests/helpers/fs_util.gd")
const K := DesignationMap.Kind

var reg: TileRegistry
var g: WorldGrid
var ids: StableIdAllocator
var des: DesignationMap
var inv: Inventory
var sp: StockpileZones
var nav: NavGrid
var jobs: JobManager
var col: Colony
var n: Npc
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
	n = col.spawn_npc(Vector2i(5, 9))
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


## No job holds a worker, item or booking; the NPC is free and empty-handed.
func _assert_clean(kg_rock: float) -> void:
	assert_eq(jobs.check_invariants(), [] as Array[String])
	assert_eq(inv.check_conservation(), [] as Array[String])
	for j in jobs.all_jobs():
		assert_eq(j.worker_id, "", "%s has no worker" % j.id)
		assert_eq(j.item_id, "", "%s reserves nothing" % j.id)
		assert_eq(j.carried_id, "")
	assert_eq(n.job_id, "")
	assert_null(inv.carried_by(n.id))
	assert_eq(sp.to_snapshot()["bookings"].size(), 0, "no bookings left")
	assert_almost_eq(float(inv.total_kg_by_material().get(&"rock", 0.0)), kg_rock, 0.001)
	for it in inv.all_items():
		assert_eq(it.holder, Inventory.Holder.GROUND)


func _wall_setup() -> String:
	inv.spawn_ground(&"rock", 25.0, Vector2i(2, 9))
	inv.spawn_ground(&"rock", 25.0, Vector2i(3, 9))
	des.designate(Rect2i(14, 9, 1, 1), K.BUILD_WALL)
	return jobs.job_at(Vector2i(14, 9)).id


func test_cancel_dig_while_walking() -> void:
	des.designate(Rect2i(20, 10, 1, 1), K.DIG)
	assert_true(_run(20, func() -> bool: return n.is_moving() and not n.job_id.is_empty()))
	des.cancel(Rect2i(20, 10, 1, 1))
	assert_eq(jobs.job_count(), 0)
	_assert_clean(0.0)
	_run(30)
	assert_eq(g.get_tile(Vector2i(20, 10)), TileRegistry.DIRT)


func test_cancel_dig_while_working() -> void:
	des.designate(Rect2i(7, 10, 1, 1), K.DIG)
	assert_true(_run(50, func() -> bool: return n.state == &"working"))
	des.cancel(Rect2i(7, 10, 1, 1))
	_assert_clean(0.0)
	_run(30)
	assert_eq(g.get_tile(Vector2i(7, 10)), TileRegistry.DIRT)
	assert_eq(inv.all_items().size(), 0)


func test_cancel_build_while_fetching() -> void:
	var jid := _wall_setup()
	assert_true(_run(20, func() -> bool:
		var j := jobs.get_job(jid)
		return j != null and j.phase == Job.PHASE_FETCH and not j.item_id.is_empty()))
	des.cancel(Rect2i(14, 9, 1, 1))
	_assert_clean(50.0)


func test_cancel_build_while_carrying() -> void:
	var jid := _wall_setup()
	assert_true(_run(100, func() -> bool: return inv.carried_by(n.id) != null and n.is_moving()))
	des.cancel(Rect2i(14, 9, 1, 1))
	assert_null(jobs.get_job(jid))
	_assert_clean(50.0)
	assert_almost_eq(inv.ground_kg_at(n.tile), 25.0, 0.001, "dropped where the NPC stands")


func test_cancel_build_partially_delivered() -> void:
	var jid := _wall_setup()
	assert_true(_run(300, func() -> bool: return inv.site_kg(jid) > 0.0 and inv.carried_by(n.id) == null))
	assert_almost_eq(inv.site_kg(jid), 25.0, 0.001)
	des.cancel(Rect2i(14, 9, 1, 1))
	assert_almost_eq(inv.site_kg(jid), 0.0, 0.001)
	assert_almost_eq(inv.ground_kg_at(Vector2i(14, 9)), 25.0, 0.001, "site material back on the ground")
	_assert_clean(50.0)


func test_cancel_build_while_working() -> void:
	var jid := _wall_setup()
	assert_true(_run(400, func() -> bool: return n.state == &"working"))
	assert_almost_eq(inv.site_kg(jid), 50.0, 0.001)
	des.cancel(Rect2i(14, 9, 1, 1))
	_assert_clean(50.0)
	assert_eq(g.get_tile(Vector2i(14, 9)), TileRegistry.AIR)


func test_order_replaced_cancels_job() -> void:
	var jid := _wall_setup()
	assert_true(_run(100, func() -> bool: return inv.carried_by(n.id) != null))
	des.designate(Rect2i(14, 9, 1, 1), K.BUILD_LADDER)  # replaces the wall order
	assert_null(jobs.get_job(jid))
	var lj := jobs.job_at(Vector2i(14, 9))
	assert_not_null(lj)
	assert_eq(lj.order_kind, K.BUILD_LADDER)
	assert_eq(jobs.check_invariants(), [] as Array[String])
	assert_true(_run(400, func() -> bool: return g.is_ladder(Vector2i(14, 9))))


func test_stop_during_haul_carry() -> void:
	sp.designate(Rect2i(30, 9, 1, 1))
	inv.spawn_ground(&"rock", 50.0, Vector2i(2, 9))
	assert_true(_run(200, func() -> bool: return inv.carried_by(n.id) != null and n.is_moving()))
	assert_true(col.command_stop(n.id).ok)
	_assert_clean(50.0)
	assert_eq(jobs.job_count(), 0, "haul jobs are recreated from the loose item later")
	assert_true(_run(600, func() -> bool: return sp.is_stored(inv.all_items()[0])))


func test_stop_during_build_delivery_returns_nothing_to_site() -> void:
	var jid := _wall_setup()
	assert_true(_run(300, func() -> bool: return inv.site_kg(jid) > 0.0 and inv.carried_by(n.id) != null))
	assert_true(col.command_stop(n.id).ok)
	assert_almost_eq(inv.site_kg(jid), 25.0, 0.001, "delivered material stays at the site")
	assert_eq(jobs.get_job(jid).worker_id, "")
	assert_eq(jobs.check_invariants(), [] as Array[String])
	assert_true(_run(800, func() -> bool: return g.get_tile(Vector2i(14, 9)) == TileRegistry.CONCRETE))
