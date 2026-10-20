extends GutTest
## Dig jobs: creation/removal from designations, priorities, reservation of
## the job by exactly one NPC, the dig flow, unreachable marking, gravity.
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


## Runs up to max_ticks, stopping early when cond returns true. Checks
## invariants and conservation every tick. Returns true if cond became true.
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


func test_jobs_follow_designations() -> void:
	assert_true(des.designate(Rect2i(5, 10, 3, 1), K.DIG).ok)
	assert_eq(jobs.job_count(), 3)
	var j := jobs.job_at(Vector2i(6, 10))
	assert_not_null(j)
	assert_eq(j.kind, Job.KIND_DIG)
	assert_eq(jobs.describe_job(j.id), "Dig (6, 10)")
	assert_true(des.designate(Rect2i(20, 9, 1, 1), K.BUILD_WALL).ok)
	assert_true(des.designate(Rect2i(21, 9, 1, 1), K.BUILD_LADDER).ok)
	assert_eq(jobs.job_count(), 5)
	assert_eq(jobs.describe_job(jobs.job_at(Vector2i(20, 9)).id), "Build wall (20, 9)")
	assert_eq(jobs.describe_job(jobs.job_at(Vector2i(21, 9)).id), "Build ladder (21, 9)")
	assert_true(des.set_priority(Rect2i(5, 10, 1, 1), 9).ok)
	assert_eq(jobs.job_at(Vector2i(5, 10)).priority, 9)
	assert_true(des.cancel(Rect2i(5, 10, 2, 1)).ok)
	assert_eq(jobs.job_count(), 3)
	assert_null(jobs.job_at(Vector2i(5, 10)))
	assert_eq(jobs.check_invariants(), [] as Array[String])


func test_jobs_built_from_existing_designations() -> void:
	des.designate(Rect2i(5, 10, 4, 1), K.DIG)
	var jm2 := JobManager.new(g, des, inv, sp, nav, ids)
	assert_eq(jm2.job_count(), 4)


func test_dig_flow() -> void:
	var n := col.spawn_npc(Vector2i(5, 9))
	des.designate(Rect2i(7, 10, 1, 1), K.DIG)
	var worked := [0]
	var done := _run(200, func() -> bool:
		if n.state == &"working":
			worked[0] += 1
		return g.get_tile(Vector2i(7, 10)) == TileRegistry.AIR)
	assert_true(done, "tile dug")
	assert_eq(worked[0], JobManager.DIG_TICKS_PER_HARDNESS - 1,
			"dirt: 10 work ticks (last tick completes the job)")
	assert_eq(jobs.job_count(), 0)
	assert_eq(des.count(), 0)
	assert_eq(n.job_id, "")
	var items := inv.items_at(Vector2i(7, 10))
	assert_eq(items.size(), 1, "one item per dug tile, landed on the new floor")
	assert_eq(items[0].material, &"dirt")
	assert_almost_eq(items[0].kg, 50.0, 0.001)


func test_dig_item_falls() -> void:
	var n := col.spawn_npc(Vector2i(5, 9))
	g.apply_edit(Rect2i(8, 10, 1, 3), WorldGrid.Edit.DIG)  # pit under (8, 10..12)
	g.apply_edit(Rect2i(7, 11, 1, 2), WorldGrid.Edit.DIG)
	# (7,10) now overhangs an open (7,11..12): its item falls to (7,12).
	des.designate(Rect2i(7, 10, 1, 1), K.DIG)
	assert_true(_run(300, func() -> bool: return g.get_tile(Vector2i(7, 10)) == TileRegistry.AIR))
	assert_eq(inv.items_at(Vector2i(7, 12)).size(), 1)
	assert_eq(inv.items_at(Vector2i(7, 10)).size(), 0)
	assert_not_null(n)


func test_priority_then_distance() -> void:
	var n := col.spawn_npc(Vector2i(5, 9))
	des.designate(Rect2i(7, 10, 1, 1), K.DIG, 1)
	des.designate(Rect2i(30, 10, 1, 1), K.DIG, 9)
	des.designate(Rect2i(25, 10, 1, 1), K.DIG, 9)
	_run(1)
	assert_eq(n.job_id, jobs.job_at(Vector2i(25, 10)).id, "priority 9 first, nearer of the two")


func test_one_job_one_worker() -> void:
	var a := col.spawn_npc(Vector2i(5, 9))
	var b := col.spawn_npc(Vector2i(6, 9))
	var c := col.spawn_npc(Vector2i(4, 9))
	des.designate(Rect2i(7, 10, 1, 1), K.DIG)
	_run(3)
	var busy := 0
	for n in [a, b, c]:
		if not (n as Npc).job_id.is_empty():
			busy += 1
	assert_eq(busy, 1, "exactly one NPC claims the single job")
	assert_true(_run(200, func() -> bool: return jobs.job_count() == 0))
	assert_eq(inv.all_items().size(), 1, "dug once")


func test_path_budget_shared_by_all_npcs() -> void:
	for i in 20:
		col.spawn_npc(Vector2i(i, 9))
	des.designate(Rect2i(25, 10, 15, 1), K.DIG)
	t += 1
	jobs.update(t)
	col.update(t)
	assert_lte(nav.budget_used(t), NavGrid.PATH_BUDGET_PER_TICK)
	var busy := 0
	for n in col.all_npcs():
		if not n.job_id.is_empty():
			busy += 1
	assert_eq(busy, NavGrid.PATH_BUDGET_PER_TICK, "only NPCs that got a path search this tick")
	_run(5)
	busy = 0
	for n in col.all_npcs():
		if not n.job_id.is_empty():
			busy += 1
	assert_eq(busy, 15, "the rest got their turn on later ticks")


func test_many_npcs_many_jobs_unique_claims() -> void:
	for i in 6:
		col.spawn_npc(Vector2i(2 + i, 9))
	des.designate(Rect2i(10, 10, 20, 1), K.DIG)
	_run(20)
	var claimed := {}
	for n in col.all_npcs():
		if not n.job_id.is_empty():
			assert_false(claimed.has(n.job_id), "job %s claimed twice" % n.job_id)
			claimed[n.job_id] = true
	assert_gt(claimed.size(), 1)
	assert_true(_run(1500, func() -> bool: return des.count() == 0))
	assert_eq(inv.all_items().size(), 20)


func test_unexposed_dig_is_unreachable_until_terrain_changes() -> void:
	var n := col.spawn_npc(Vector2i(5, 9))
	des.designate(Rect2i(7, 11, 1, 1), K.DIG)  # buried under (7, 10)
	_run(3)
	assert_true(jobs.is_unreachable(Vector2i(7, 11)))
	assert_eq(n.job_id, "")
	assert_true(jobs.describe_job(jobs.job_at(Vector2i(7, 11)).id).contains("unreachable"))
	g.apply_edit(Rect2i(7, 10, 1, 1), WorldGrid.Edit.DIG)  # expose it
	assert_false(jobs.is_unreachable(Vector2i(7, 11)), "tiles_changed nearby re-opens it")
	assert_true(_run(300, func() -> bool: return g.get_tile(Vector2i(7, 11)) == TileRegistry.AIR))


func test_unreachable_retry_after_timeout() -> void:
	var n := col.spawn_npc(Vector2i(5, 9))
	# A closed cave far below: exposed (has air) but no path to it.
	g.apply_edit(Rect2i(20, 20, 3, 3), WorldGrid.Edit.DIG)
	des.designate(Rect2i(23, 21, 1, 1), K.DIG)
	_run(2)
	assert_true(jobs.is_unreachable(Vector2i(23, 21)))
	_run(JobManager.UNREACHABLE_RETRY_TICKS + 20)
	assert_true(jobs.is_unreachable(Vector2i(23, 21)), "re-marked after the retry")
	assert_eq(n.job_id, "")


func test_confined_npc_stops_searching_and_blocks_nobody() -> void:
	g.apply_edit(Rect2i(30, 10, 3, 3), WorldGrid.Edit.DIG)  # 3-deep pit: no way out
	var a := col.spawn_npc(Vector2i(31, 12))
	des.designate(Rect2i(5, 10, 1, 1), K.DIG)
	_run(3)
	assert_true(a._region_valid, "exhaustive failed search recorded its region")
	assert_true(jobs.is_unreachable(Vector2i(5, 10)), "the only NPC cannot reach it")
	var searches := nav.searches_total
	_run(60)
	assert_eq(nav.searches_total, searches, "no more searches for jobs outside its region")
	var b := col.spawn_npc(Vector2i(3, 9))
	assert_false(jobs.is_unreachable(Vector2i(5, 10)), "a new NPC re-opens the job at once")
	assert_true(_run(100, func() -> bool: return g.get_tile(Vector2i(5, 10)) == TileRegistry.AIR))
	assert_eq(a.tile, Vector2i(31, 12), "still in its pit")
	assert_not_null(b)
	# Building a way out (terrain change next to the pit) forgets the region.
	g.apply_edit(Rect2i(33, 10, 1, 1), WorldGrid.Edit.DIG)
	assert_false(a._region_valid)


func test_gravity_after_digging_under_npc() -> void:
	var n := col.spawn_npc(Vector2i(5, 9))
	des.designate(Rect2i(5, 10, 1, 1), K.DIG)  # its own floor
	assert_true(_run(100, func() -> bool: return g.get_tile(Vector2i(5, 10)) == TileRegistry.AIR))
	_run(10)
	assert_eq(n.tile, Vector2i(5, 10), "fell onto the new floor")
	assert_true(nav.can_stand(n.tile))


func test_gravity_when_terrain_vanishes() -> void:
	var n := col.spawn_npc(Vector2i(5, 9))
	_run(1)
	g.apply_edit(Rect2i(5, 10, 1, 3), WorldGrid.Edit.DIG)
	_run(1)
	assert_eq(n.tile, Vector2i(5, 12))
	assert_true(n.is_moving(), "falling is animated")
	_run(10)
	assert_false(n.is_moving())
	assert_eq(n.prev_tile, Vector2i(5, 12))


func test_work_toggle_filters_dig() -> void:
	var n := col.spawn_npc(Vector2i(5, 9))
	assert_true(col.set_work_enabled(n.id, &"dig", false).ok)
	des.designate(Rect2i(7, 10, 1, 1), K.DIG)
	_run(30)
	assert_eq(n.job_id, "")
	assert_eq(g.get_tile(Vector2i(7, 10)), TileRegistry.DIRT)
	col.set_work_enabled(n.id, &"dig", true)
	assert_true(_run(100, func() -> bool: return g.get_tile(Vector2i(7, 10)) == TileRegistry.AIR))


func test_buried_order_stays_unreachable_without_flicker() -> void:
	col.spawn_npc(Vector2i(5, 9))
	des.designate(Rect2i(7, 15, 1, 1), K.DIG)  # touches no air
	_run(2)
	var flagged := [0]
	_run(400, func() -> bool:
		if jobs.is_unreachable(Vector2i(7, 15)):
			flagged[0] += 1
		return false)
	assert_eq(flagged[0], 400, "flagged on every tick until terrain changes")
	g.apply_edit(Rect2i(7, 10, 1, 5), WorldGrid.Edit.DIG)  # shaft down to it
	assert_false(jobs.is_unreachable(Vector2i(7, 15)))
