extends GutTest
## Colony: spawning, movement speed, Move here / Stop job, work toggles,
## npc_at. Grid 40x30 from fs_util.make_grid: rows < 10 air, 10..28 dirt.

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


func test_spawn_starting_npcs() -> void:
	watch_signals(col)
	col.spawn_starting_npcs()
	assert_eq(col.count(), Colony.START_NPCS)
	assert_signal_emitted(col, "npcs_changed")
	var xs := {}
	for npc in col.all_npcs():
		assert_true(nav.can_stand(npc.tile), "%s on a standable tile" % npc.id)
		assert_eq(npc.tile.y, 9, "on the surface")
		assert_lte(absi(npc.tile.x - 20), 8, "near the centre column")
		xs[npc.tile.x] = true
		assert_eq(npc.state, &"idle")
		assert_eq(npc.command_target, Npc.NO_TILE)
		assert_true(npc.id.begins_with("npc:"))
	assert_eq(xs.size(), Colony.START_NPCS, "distinct columns")


func test_walk_speed_and_interpolation() -> void:
	var n := col.spawn_npc(Vector2i(5, 9))
	assert_true(col.command_move(n.id, Vector2i(15, 9)).ok)
	var progress_seen := {}
	var ticks := [0]
	assert_true(_run(200, func() -> bool:
		ticks[0] += 1
		if n.is_moving():
			progress_seen[snappedf(n.move_progress, 0.01)] = true
			assert_eq(absi(n.tile.x - n.prev_tile.x), 1)
		return n.tile == Vector2i(15, 9) and not n.is_moving()))
	# The first tick starts the walk; then 5 ticks per step (2 tiles/s at 10 Hz).
	assert_eq(ticks[0], 1 + 10 * NavGrid.TICKS_PER_STEP, "10 tiles at 5 ticks per step")
	assert_gt(progress_seen.size(), 2, "move_progress advances per tick")
	assert_eq(n.command_target, Npc.NO_TILE, "command done")
	assert_eq(n.state, &"idle")


func test_command_move_releases_job_and_drops_item() -> void:
	var n := col.spawn_npc(Vector2i(5, 9))
	inv.spawn_ground(&"rock", 50.0, Vector2i(2, 9))
	des.designate(Rect2i(14, 9, 1, 1), K.BUILD_WALL)
	assert_true(_run(100, func() -> bool: return inv.carried_by(n.id) != null and n.is_moving()))
	var jid := n.job_id
	var r := col.command_move(n.id, Vector2i(30, 9))
	assert_true(r.ok, str(r))
	assert_eq(r.data["target"], Vector2i(30, 9))
	assert_eq(n.job_id, "")
	assert_null(inv.carried_by(n.id))
	assert_eq(jobs.get_job(jid).worker_id, "")
	assert_eq(jobs.check_invariants(), [] as Array[String])
	assert_true(_run(200, func() -> bool: return n.tile == Vector2i(30, 9) and not n.is_moving()))


func test_command_move_to_nearest_standable() -> void:
	var n := col.spawn_npc(Vector2i(5, 9))
	var r := col.command_move(n.id, Vector2i(20, 5))  # mid-air
	assert_true(r.ok)
	assert_eq(r.data["target"], Vector2i(20, 9))


func test_command_move_failures() -> void:
	var n := col.spawn_npc(Vector2i(5, 9))
	assert_eq(col.command_move("npc:99", Vector2i(10, 9)).code, &"unknown_npc")
	assert_eq(col.command_move(n.id, Vector2i(-5, 9)).code, &"out_of_bounds")
	assert_eq(col.command_move(n.id, Vector2i(20, 22)).code, &"no_standable_tile", "deep in solid dirt")
	g.apply_edit(Rect2i(30, 20, 3, 3), WorldGrid.Edit.DIG)  # closed cave
	var r := col.command_move(n.id, Vector2i(31, 22))
	assert_eq(r.code, &"unreachable")
	assert_eq(n.command_target, Npc.NO_TILE, "failed command changes nothing")


func test_command_stop_ignores_job_for_a_while() -> void:
	var n := col.spawn_npc(Vector2i(5, 9))
	des.designate(Rect2i(25, 10, 1, 1), K.DIG)
	assert_true(_run(10, func() -> bool: return not n.job_id.is_empty()))
	var r := col.command_stop(n.id)
	assert_true(r.ok)
	assert_false(String(r.data["released_job"]).is_empty())
	assert_eq(n.job_id, "")
	_run(Colony.STOP_IGNORE_TICKS - 5)
	assert_eq(n.job_id, "", "job ignored after Stop")
	assert_true(_run(30, func() -> bool: return not n.job_id.is_empty()), "taken again later")
	assert_eq(col.command_stop("npc:99").code, &"unknown_npc")


func test_set_work_enabled_validates() -> void:
	var n := col.spawn_npc(Vector2i(5, 9))
	assert_eq(col.set_work_enabled(n.id, &"sing", false).code, &"invalid_work")
	assert_eq(col.set_work_enabled("npc:99", &"dig", false).code, &"unknown_npc")
	assert_true(col.set_work_enabled(n.id, &"haul", false).ok)
	assert_false(n.work_enabled[&"haul"])
	# Disabling the work type of the current job releases it.
	des.designate(Rect2i(25, 10, 1, 1), K.DIG)
	assert_true(_run(5, func() -> bool: return not n.job_id.is_empty()))
	col.set_work_enabled(n.id, &"dig", false)
	assert_eq(n.job_id, "")
	assert_eq(jobs.check_invariants(), [] as Array[String])


func test_npc_at_covers_body() -> void:
	var n := col.spawn_npc(Vector2i(5, 9))
	assert_eq(col.npc_at(Vector2i(5, 9)), n)
	assert_eq(col.npc_at(Vector2i(5, 7)), n)
	assert_null(col.npc_at(Vector2i(5, 6)))
	assert_null(col.npc_at(Vector2i(6, 9)))
	assert_eq(col.get_npc(n.id), n)
	assert_null(col.get_npc("npc:42"))


func test_npcs_never_climb_walls() -> void:
	var n := col.spawn_npc(Vector2i(5, 12))
	g.apply_edit(Rect2i(3, 10, 5, 3), WorldGrid.Edit.DIG)  # 3-deep pit, floor at 13
	_run(2)
	assert_eq(col.command_move(n.id, Vector2i(20, 9)).code, &"unreachable")
