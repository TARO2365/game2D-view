extends GutTest
## Save/load in the middle of work: an NPC carrying material, a partially
## delivered build site, a half-dug tile and a booked haul job restore without
## duplication or loss, then finish. Also: invalid snapshot data is released.
## Grid 40x30 from fs_util.make_grid: rows < 10 air, 10..28 dirt, 29 bedrock.

const FS := preload("res://tests/helpers/fs_util.gd")
const K := DesignationMap.Kind


class Env:
	var g: WorldGrid
	var ids := StableIdAllocator.new()
	var des: DesignationMap
	var inv: Inventory
	var sp: StockpileZones
	var nav: NavGrid
	var jobs: JobManager
	var col: Colony

	func _init(grid: WorldGrid) -> void:
		g = grid
		des = DesignationMap.new(g)
		inv = Inventory.new(ids)
		sp = StockpileZones.new(g, inv)
		nav = NavGrid.new(g, 3)
		jobs = JobManager.new(g, des, inv, sp, nav, ids)
		col = Colony.new(g, nav, jobs, ids, 42)

	func step(tick: int) -> Array[String]:
		jobs.update(tick)
		col.update(tick)
		var errs := jobs.check_invariants()
		errs.append_array(inv.check_conservation())
		return errs

	## Everything a save stores for these modules, through var_to_bytes.
	func snapshot() -> Dictionary:
		var s := {
			"tiles": g.tiles.duplicate(),
			"structures": g.structures.duplicate(),
			"ids": ids.to_snapshot(),
			"des": des.to_snapshot(),
			"inv": inv.to_snapshot(),
			"sp": sp.to_snapshot(),
			"jobs": jobs.to_snapshot(),
			"col": col.to_snapshot(),
		}
		return bytes_to_var(var_to_bytes(s))


var reg: TileRegistry
var t := 0


func before_all() -> void:
	reg = TileRegistry.load_default()


func _fresh_grid() -> WorldGrid:
	return FS.make_grid(reg, Vector2i(40, 30))


## Load order for the Lead: ids, designations, inventory, stockpiles, colony, jobs.
func _load(s: Dictionary) -> Env:
	var g := _fresh_grid()
	g.tiles = s["tiles"]
	g.structures = s["structures"]
	var e := Env.new(g)
	e.ids.load_snapshot(s["ids"])
	assert_eq(e.des.load_snapshot(s["des"]), 0)
	assert_eq(e.inv.load_snapshot(s["inv"]), 0)
	assert_eq(e.sp.load_snapshot(s["sp"]), 0)
	assert_eq(e.col.load_snapshot(s["col"]), 0)
	assert_eq(e.jobs.load_snapshot(s["jobs"]), 0)
	return e


func _run(e: Env, max_ticks: int, cond: Callable = Callable()) -> bool:
	for i in max_ticks:
		t += 1
		var errs := e.step(t)
		if not errs.is_empty():
			fail_test("tick %d: %s" % [t, errs])
			return false
		if cond.is_valid() and cond.call():
			return true
	return false


func test_round_trip_mid_work() -> void:
	t = 0
	var g := _fresh_grid()
	g.tiles[10 * g.width + 12] = TileRegistry.ROCK  # hardness 2 -> 20 dig ticks
	var e := Env.new(g)
	var builder := e.col.spawn_npc(Vector2i(5, 9))
	var digger := e.col.spawn_npc(Vector2i(11, 9))
	for w in Npc.WORK_KEYS:
		e.col.set_work_enabled(builder.id, w, w == &"build")
		e.col.set_work_enabled(digger.id, w, false)
	e.inv.spawn_ground(&"rock", 25.0, Vector2i(2, 9))
	e.inv.spawn_ground(&"rock", 25.0, Vector2i(3, 9))
	e.inv.spawn_ground(&"dirt", 40.0, Vector2i(8, 9))  # loose, nobody hauls: booked haul job
	e.sp.designate(Rect2i(35, 9, 2, 1))
	e.des.designate(Rect2i(30, 9, 1, 1), K.BUILD_WALL)
	e.des.designate(Rect2i(12, 10, 1, 1), K.DIG)
	var wall_id := e.jobs.job_at(Vector2i(30, 9)).id
	var dig_id := e.jobs.job_at(Vector2i(12, 10)).id
	# 1) builder delivered one stack and carries the second.
	assert_true(_run(e, 600, func() -> bool:
		return e.inv.site_kg(wall_id) > 0.0 and e.inv.carried_by(builder.id) != null))
	# 2) digger half-way through the rock tile.
	e.col.set_work_enabled(digger.id, &"dig", true)
	assert_true(_run(e, 100, func() -> bool: return e.jobs.get_job(dig_id).work_ticks >= 8))
	assert_not_null(e.inv.carried_by(builder.id), "still carrying")
	var carried_id := e.inv.carried_by(builder.id).id
	var dig_ticks := e.jobs.get_job(dig_id).work_ticks
	var haul: Job = null
	for j in e.jobs.all_jobs():
		if j.kind == Job.KIND_HAUL:
			haul = j
	assert_not_null(haul, "haul job with a booking exists")
	var haul_tile := e.sp.booked_tile(haul.id)
	assert_ne(haul_tile, StockpileZones.NO_TILE)
	var totals := e.inv.total_kg_by_material()
	var item_count := e.inv.all_items().size()

	var s := e.snapshot()
	var e2 := _load(s)
	assert_eq(e2.jobs.check_invariants(), [] as Array[String])
	assert_eq(e2.inv.check_conservation(), [] as Array[String])
	assert_eq(e2.inv.all_items().size(), item_count, "no item duplicated or lost")
	assert_eq(e2.inv.total_kg_by_material(), totals)
	var b2 := e2.col.get_npc(builder.id)
	var d2 := e2.col.get_npc(digger.id)
	assert_eq(b2.job_id, wall_id)
	assert_eq(e2.inv.carried_by(b2.id).id, carried_id)
	assert_eq(e2.jobs.get_job(wall_id).carried_id, carried_id)
	assert_eq(e2.jobs.get_job(wall_id).phase, Job.PHASE_DELIVER)
	assert_almost_eq(e2.inv.site_kg(wall_id), 25.0, 0.001)
	assert_eq(d2.job_id, dig_id)
	assert_eq(e2.jobs.get_job(dig_id).work_ticks, dig_ticks, "dig progress kept")
	assert_eq(e2.sp.booked_tile(haul.id), haul_tile)
	assert_eq(e2.jobs.job_count(), e.jobs.job_count())
	assert_false(b2.work_enabled[&"dig"])
	# Snapshot of the loaded state equals the original (nothing re-created).
	assert_eq(e2.jobs.to_snapshot(), s["jobs"])
	# Everything finishes after load.
	for n in e2.col.all_npcs():
		for w in Npc.WORK_KEYS:
			e2.col.set_work_enabled(n.id, w, true)
	assert_true(_run(e2, 1500, func() -> bool:
		return e2.g.get_tile(Vector2i(30, 9)) == TileRegistry.CONCRETE \
				and e2.g.get_tile(Vector2i(12, 10)) == TileRegistry.AIR and e2.jobs.job_count() == 0))
	assert_eq(e2.des.count(), 0)


func test_load_releases_inconsistent_reservations() -> void:
	t = 0
	var e := Env.new(_fresh_grid())
	var n := e.col.spawn_npc(Vector2i(5, 9))
	var item := e.inv.spawn_ground(&"rock", 50.0, Vector2i(2, 9))
	e.des.designate(Rect2i(14, 9, 1, 1), K.BUILD_WALL)
	e.des.designate(Rect2i(20, 9, 1, 1), K.BUILD_WALL)
	assert_true(_run(e, 5, func() -> bool: return not n.job_id.is_empty()))
	var s := e.snapshot()
	# Corrupt: both jobs claim the same item and the same worker; plus junk.
	var list: Array = s["jobs"]["jobs"]
	for d: Dictionary in list:
		d["item_id"] = item
		d["worker_id"] = n.id
	list.append({"id": "job:999", "kind": "dig", "tile": Vector2i(1, 1), "phase": "work"})
	list.append("junk")
	var g := _fresh_grid()
	g.tiles = s["tiles"]
	g.structures = s["structures"]
	var e2 := Env.new(g)
	e2.ids.load_snapshot(s["ids"])
	e2.des.load_snapshot(s["des"])
	e2.inv.load_snapshot(s["inv"])
	e2.sp.load_snapshot(s["sp"])
	e2.col.load_snapshot(s["col"])
	assert_eq(e2.jobs.load_snapshot(s["jobs"]), 2, "the order-less dig job and the junk entry")
	assert_eq(e2.jobs.check_invariants(), [] as Array[String])
	assert_eq(e2.jobs.job_count(), 2)
	var claims := 0
	for j in e2.jobs.all_jobs():
		if j.item_id == item:
			claims += 1
	assert_lte(claims, 1, "the stack is reserved once at most")
	assert_true(_run(e2, 400, func() -> bool:
		return e2.g.get_tile(Vector2i(14, 9)) == TileRegistry.CONCRETE \
				or e2.g.get_tile(Vector2i(20, 9)) == TileRegistry.CONCRETE))


func test_npc_on_unstandable_tile_after_load() -> void:
	var e := Env.new(_fresh_grid())
	e.col.spawn_npc(Vector2i(5, 9))
	var s := e.snapshot()
	var g := _fresh_grid()
	g.tiles = s["tiles"]
	# Terrain under the NPC differs in this load (e.g. edited save): a 2-deep hole.
	for y in [10, 11]:
		g.tiles[y * g.width + 5] = TileRegistry.AIR
	var e2 := Env.new(g)
	e2.col.load_snapshot(s["col"])
	var n: Npc = e2.col.all_npcs()[0]
	assert_true(e2.nav.can_stand(n.tile))
	assert_eq(n.tile, Vector2i(5, 11))


func test_orders_without_jobs_get_jobs_on_load() -> void:
	var e := Env.new(_fresh_grid())
	e.des.designate(Rect2i(5, 10, 3, 1), K.DIG)
	var s := e.snapshot()
	s["jobs"] = {"jobs": []}  # e.g. a save from before jobs existed
	var e2 := _load(s)
	assert_eq(e2.jobs.job_count(), 3)
