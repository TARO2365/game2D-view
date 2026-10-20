extends GutTest
## M3 save/load in the middle of work: a building order with material
## partially delivered and the builder carrying the next stack, a building
## being deconstructed, a haul booked into a crate. Snapshots go through
## var_to_bytes and are loaded in SaveService v3 order (buildings,
## designations, inventory, stockpiles, crates, build_orders, colony, jobs).
## Grid 40x30 from fs_util.make_grid: rows < 10 air, 10..28 dirt.

const FS := preload("res://tests/helpers/fs_util.gd")
const K := DesignationMap.Kind


class Env:
	var g: WorldGrid
	var ids := StableIdAllocator.new()
	var bld: Buildings
	var des: DesignationMap
	var inv: Inventory
	var sp: StockpileZones
	var crates: CrateStorage
	var orders: BuildOrders
	var nav: NavGrid
	var jobs: JobManager
	var col: Colony

	func _init(grid: WorldGrid) -> void:
		g = grid
		bld = Buildings.new(g, ids)
		des = DesignationMap.new(g)
		inv = Inventory.new(ids)
		sp = StockpileZones.new(g, inv)
		crates = CrateStorage.new(bld, inv)
		orders = BuildOrders.new(g, bld, des, ids)
		nav = NavGrid.new(g, 3)
		jobs = JobManager.new(g, des, inv, sp, nav, ids, bld, crates, orders)
		col = Colony.new(g, nav, jobs, ids, 42)

	func step(tick: int) -> Array[String]:
		jobs.update(tick)
		col.update(tick)
		var errs := jobs.check_invariants()
		errs.append_array(inv.check_conservation())
		return errs

	func snapshot() -> Dictionary:
		return bytes_to_var(var_to_bytes({
			"tiles": g.tiles.duplicate(), "structures": g.structures.duplicate(),
			"ids": ids.to_snapshot(), "buildings": bld.to_snapshot(), "des": des.to_snapshot(),
			"inv": inv.to_snapshot(), "sp": sp.to_snapshot(), "crates": crates.to_snapshot(),
			"orders": orders.to_snapshot(), "col": col.to_snapshot(), "jobs": jobs.to_snapshot(),
		}))


var reg: TileRegistry
var t := 0


func before_all() -> void:
	reg = TileRegistry.load_default()


func _load(s: Dictionary) -> Env:
	var g := FS.make_grid(reg, Vector2i(40, 30))
	g.tiles = s["tiles"]
	g.structures = s["structures"]
	var e := Env.new(g)
	e.ids.load_snapshot(s["ids"])
	assert_eq(e.bld.load_snapshot(s["buildings"]), 0)
	assert_eq(e.des.load_snapshot(s["des"]), 0)
	assert_eq(e.inv.load_snapshot(s["inv"]), 0)
	assert_eq(e.sp.load_snapshot(s["sp"]), 0)
	assert_eq(e.crates.load_snapshot(s["crates"]), 0)
	assert_eq(e.orders.load_snapshot(s["orders"]), 0)
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


func test_round_trip_mid_build_and_mid_deconstruct() -> void:
	t = 0
	var e := Env.new(FS.make_grid(reg, Vector2i(40, 30)))
	var builder := e.col.spawn_npc(Vector2i(8, 9))
	var wrecker := e.col.spawn_npc(Vector2i(30, 9))
	for w in Npc.WORK_KEYS:
		e.col.set_work_enabled(builder.id, w, w == &"build")
		e.col.set_work_enabled(wrecker.id, w, false)
	e.inv.spawn_ground(&"rock", 25.0, Vector2i(2, 9))
	e.inv.spawn_ground(&"rock", 25.0, Vector2i(3, 9))
	var cid: String = e.bld.place(&"crate", Vector2i(36, 9), {&"dirt": 50.0}).data["id"]
	var bed: String = e.bld.place(&"bed", Vector2i(32, 9), {&"rock": 50.0}).data["id"]
	e.inv.spawn_ground(&"dirt", 40.0, Vector2i(10, 9))  # loose: haul booked into the crate
	assert_true(e.orders.order_building(&"table", Vector2i(20, 9)).ok)
	var table_job := e.jobs.job_at(Vector2i(20, 9)).id
	# Builder delivered one stack and carries the second.
	assert_true(_run(e, 800, func() -> bool:
		return e.inv.site_kg(table_job) > 0.0 and e.inv.carried_by(builder.id) != null))
	# Wrecker half-way through the bed.
	e.des.designate(Rect2i(32, 9, 2, 1), K.DECONSTRUCT)
	var decon := e.jobs.job_at(Vector2i(33, 9)).id
	e.col.set_work_enabled(wrecker.id, &"build", true)
	# The builder is busy with the table: only the wrecker takes the bed.
	assert_true(_run(e, 200, func() -> bool: return e.jobs.get_job(decon).work_ticks >= 8))
	assert_not_null(e.inv.carried_by(builder.id))
	var haul: Job = null
	for j in e.jobs.all_jobs():
		if j.kind == Job.KIND_HAUL:
			haul = j
	assert_not_null(haul)
	assert_eq(e.crates.booked_crate(haul.id), cid, "loose stack booked into the crate")
	var carried := e.inv.carried_by(builder.id).id
	var decon_ticks := e.jobs.get_job(decon).work_ticks
	var totals := e.inv.total_kg_by_material()
	var items := e.inv.all_items().size()

	var s := e.snapshot()
	var e2 := _load(s)
	assert_eq(e2.jobs.check_invariants(), [] as Array[String])
	assert_eq(e2.inv.check_conservation(), [] as Array[String])
	assert_eq(e2.inv.all_items().size(), items, "no item duplicated or lost")
	assert_eq(e2.inv.total_kg_by_material(), totals)
	assert_eq(e2.inv.carried_by(builder.id).id, carried)
	assert_eq(e2.jobs.get_job(table_job).phase, Job.PHASE_DELIVER)
	assert_almost_eq(e2.inv.site_kg(table_job), 25.0, 0.001)
	assert_eq(e2.jobs.get_job(decon).work_ticks, decon_ticks)
	assert_eq(e2.jobs.get_job(decon).order_id, bed)
	assert_eq(e2.jobs.job_at(Vector2i(32, 9)), e2.jobs.get_job(decon), "both bed tiles map to one job")
	assert_eq(e2.crates.booked_crate(haul.id), cid)
	assert_eq(e2.jobs.to_snapshot(), s["jobs"], "nothing re-created")
	for n in e2.col.all_npcs():
		for w in Npc.WORK_KEYS:
			e2.col.set_work_enabled(n.id, w, true)
	assert_true(_run(e2, 2000, func() -> bool:
		return e2.bld.get_building(bed).is_empty() and e2.orders.count() == 0 \
				and e2.jobs.job_count() == 0))
	var keys := []
	for id in e2.bld.all_ids():
		keys.append(String(e2.bld.get_building(id)["key"]))
	keys.sort()
	assert_eq(keys, ["crate", "table"])
	assert_eq(e2.des.count(), 0)


func test_orphan_building_jobs_dropped_on_load() -> void:
	t = 0
	var e := Env.new(FS.make_grid(reg, Vector2i(40, 30)))
	e.orders.order_building(&"bed", Vector2i(10, 9))
	var s := e.snapshot()
	s["orders"] = {"orders": []}  # order gone (e.g. edited save) -> its job is dropped
	var e2 := _load_lenient(s)
	assert_eq(e2.jobs.job_count(), 0)
	assert_eq(e2.jobs.check_invariants(), [] as Array[String])


func _load_lenient(s: Dictionary) -> Env:
	var g := FS.make_grid(reg, Vector2i(40, 30))
	g.tiles = s["tiles"]
	g.structures = s["structures"]
	var e := Env.new(g)
	e.ids.load_snapshot(s["ids"])
	e.bld.load_snapshot(s["buildings"])
	e.des.load_snapshot(s["des"])
	e.inv.load_snapshot(s["inv"])
	e.sp.load_snapshot(s["sp"])
	e.crates.load_snapshot(s["crates"])
	e.orders.load_snapshot(s["orders"])
	e.col.load_snapshot(s["col"])
	assert_eq(e.jobs.load_snapshot(s["jobs"]), 1, "the building job without an order")
	return e
