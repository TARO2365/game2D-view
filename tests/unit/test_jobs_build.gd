extends GutTest
## Build jobs (wall / ladder): material reservation, hauling to the site,
## "no material", multiple deliveries, waiting for NPC bodies.
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


func test_wall_flow() -> void:
	col.spawn_npc(Vector2i(5, 9))
	inv.spawn_ground(&"rock", 50.0, Vector2i(2, 9))
	des.designate(Rect2i(12, 9, 1, 1), K.BUILD_WALL)
	assert_true(_run(400, func() -> bool: return g.get_tile(Vector2i(12, 9)) == TileRegistry.CONCRETE))
	assert_eq(jobs.job_count(), 0)
	assert_eq(des.count(), 0)
	assert_almost_eq(_kg(&"rock"), 0.0, 0.001)
	assert_almost_eq(float(inv.consumed_kg_by_material().get(&"rock", 0.0)), 50.0, 0.001)


func test_ladder_flow_splits_material() -> void:
	col.spawn_npc(Vector2i(5, 9))
	inv.spawn_ground(&"dirt", 50.0, Vector2i(2, 9))
	des.designate(Rect2i(12, 9, 1, 1), K.BUILD_LADDER)
	assert_true(_run(400, func() -> bool: return g.is_ladder(Vector2i(12, 9))))
	assert_eq(jobs.job_count(), 0)
	assert_almost_eq(_kg(&"dirt"), 25.0, 0.001, "ladder takes 25 kg, the rest stays")
	assert_almost_eq(inv.ground_kg_at(Vector2i(2, 9)), 25.0, 0.001)


func test_multiple_deliveries() -> void:
	col.spawn_npc(Vector2i(5, 9))
	inv.spawn_ground(&"rock", 20.0, Vector2i(2, 9))
	inv.spawn_ground(&"rock", 20.0, Vector2i(3, 9))
	inv.spawn_ground(&"rock", 20.0, Vector2i(30, 9))
	des.designate(Rect2i(12, 9, 1, 1), K.BUILD_WALL)
	var job_id := jobs.job_at(Vector2i(12, 9)).id
	var max_site := [0.0]
	assert_true(_run(800, func() -> bool:
		max_site[0] = maxf(max_site[0], inv.site_kg(job_id))
		return g.get_tile(Vector2i(12, 9)) == TileRegistry.CONCRETE))
	assert_almost_eq(max_site[0], 50.0, 0.001, "exactly the recipe amount delivered")
	assert_almost_eq(_kg(&"rock"), 10.0, 0.001, "60 - 50 consumed")


func test_no_material_waits() -> void:
	var n := col.spawn_npc(Vector2i(5, 9))
	inv.spawn_ground(&"dirt", 50.0, Vector2i(2, 9))  # walls need rock
	des.designate(Rect2i(12, 9, 1, 1), K.BUILD_WALL)
	_run(40)
	var j := jobs.job_at(Vector2i(12, 9))
	assert_eq(j.wait_reason, JobManager.REASON_NO_MATERIAL)
	assert_true(jobs.describe_job(j.id).contains("no material"))
	assert_eq(n.job_id, "")
	assert_eq(j.worker_id, "")
	assert_eq(g.get_tile(Vector2i(12, 9)), TileRegistry.AIR)
	inv.spawn_ground(&"rock", 50.0, Vector2i(20, 9))
	assert_true(_run(400, func() -> bool: return g.get_tile(Vector2i(12, 9)) == TileRegistry.CONCRETE))


func test_two_builds_one_item() -> void:
	var a := col.spawn_npc(Vector2i(5, 9))
	var b := col.spawn_npc(Vector2i(6, 9))
	inv.spawn_ground(&"rock", 50.0, Vector2i(2, 9))
	des.designate(Rect2i(12, 9, 1, 1), K.BUILD_WALL)
	des.designate(Rect2i(14, 9, 1, 1), K.BUILD_WALL)
	_run(3)
	var reserved := 0
	for j in jobs.all_jobs():
		if not j.item_id.is_empty() or not j.carried_id.is_empty():
			reserved += 1
	assert_eq(reserved, 1, "the single stack is reserved by one job only")
	assert_true(a.job_id.is_empty() != b.job_id.is_empty(), "only one NPC got work")
	_run(400)
	var built := 0
	for x: int in [12, 14]:
		if g.get_tile(Vector2i(x, 9)) == TileRegistry.CONCRETE:
			built += 1
	assert_eq(built, 1)
	assert_eq(jobs.job_count(), 1)
	assert_eq(jobs.all_jobs()[0].wait_reason, JobManager.REASON_NO_MATERIAL)


func test_wall_waits_for_npc_body() -> void:
	var builder := col.spawn_npc(Vector2i(5, 9))
	var idler := col.spawn_npc(Vector2i(12, 9))
	for w in Npc.WORK_KEYS:
		col.set_work_enabled(idler.id, w, false)
	inv.spawn_ground(&"rock", 50.0, Vector2i(2, 9))
	des.designate(Rect2i(12, 8, 1, 1), K.BUILD_WALL)  # inside the idler's body
	var j := jobs.job_at(Vector2i(12, 8))
	assert_true(_run(400, func() -> bool: return j.wait_reason == JobManager.REASON_BLOCKED))
	assert_eq(g.get_tile(Vector2i(12, 8)), TileRegistry.AIR)
	assert_eq(builder.job_id, j.id, "builder keeps the job while waiting")
	assert_true(col.command_move(idler.id, Vector2i(20, 9)).ok)
	assert_true(_run(200, func() -> bool: return g.get_tile(Vector2i(12, 8)) == TileRegistry.CONCRETE))
	assert_eq(col.npc_at(Vector2i(12, 8)), null)


func test_material_taken_from_stockpile_and_from_haul() -> void:
	var n := col.spawn_npc(Vector2i(5, 9))
	col.set_work_enabled(n.id, &"haul", false)
	sp.designate(Rect2i(30, 9, 2, 1))
	inv.spawn_ground(&"rock", 50.0, Vector2i(31, 9))  # stored
	inv.spawn_ground(&"rock", 50.0, Vector2i(2, 9))   # loose -> haul job, nobody hauls
	_run(10)
	assert_eq(jobs.job_count(), 1, "haul job for the loose stack")
	des.designate(Rect2i(12, 9, 1, 1), K.BUILD_WALL)
	des.designate(Rect2i(14, 9, 1, 1), K.BUILD_WALL)
	assert_true(_run(800, func() -> bool:
		return g.get_tile(Vector2i(12, 9)) == TileRegistry.CONCRETE \
				and g.get_tile(Vector2i(14, 9)) == TileRegistry.CONCRETE))
	assert_eq(jobs.job_count(), 0, "the unstarted haul job gave its stack up")
	assert_eq(sp.to_snapshot()["bookings"].size(), 0, "its booking was released")
