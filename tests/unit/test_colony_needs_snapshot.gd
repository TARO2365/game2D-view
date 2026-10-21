extends GutTest
## M4a save/load in the middle of needs activities: one NPC carrying its
## meal, one asleep in its bed, one cooking (input delivered to the kitchen
## site), one collapsed. Snapshots go through var_to_bytes and are loaded in
## SaveService v4 order (buildings, designations, inventory, stockpiles,
## crates, build_orders, farming, kitchens, colony, jobs). Also: an M3-era
## colony snapshot (no needs fields) loads fed, rested, default schedule.

const FS := preload("res://tests/helpers/fs_util.gd")
const H := GameTime.TICKS_PER_HOUR


class Env:
	var g: WorldGrid
	var ids := StableIdAllocator.new()
	var bld: Buildings
	var des: DesignationMap
	var inv: Inventory
	var sp: StockpileZones
	var rooms: RoomMap
	var mats := MaterialDefs.load_default()
	var crates: CrateStorage
	var farming: Farming
	var kitchens: Kitchens
	var orders: BuildOrders
	var nav: NavGrid
	var jobs: JobManager
	var col: Colony
	var alerts := AlertService.new()

	func _init(grid: WorldGrid) -> void:
		g = grid
		bld = Buildings.new(g, ids)
		des = DesignationMap.new(g)
		inv = Inventory.new(ids)
		sp = StockpileZones.new(g, inv)
		rooms = RoomMap.new(g, bld)
		crates = CrateStorage.new(bld, inv, mats)
		farming = Farming.new(bld, inv, ids)
		kitchens = Kitchens.new(bld, inv)
		orders = BuildOrders.new(g, bld, des, ids)
		nav = NavGrid.new(g, 3)
		jobs = JobManager.new(g, des, inv, sp, nav, ids, bld, crates, orders)
		jobs.attach_m4a(mats, farming, kitchens)
		col = Colony.new(g, nav, jobs, ids, 42)
		col.attach_m4a(alerts, rooms)

	func step(tick: int) -> Array[String]:
		alerts.current_tick = tick
		farming.update(tick)
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
			"orders": orders.to_snapshot(), "farming": farming.to_snapshot(),
			"kitchens": kitchens.to_snapshot(), "col": col.to_snapshot(), "jobs": jobs.to_snapshot(),
		}))


var reg: TileRegistry
var t := 0


func before_all() -> void:
	reg = TileRegistry.load_default()


## First tick of the day at hour:minute (GameTime may offset tick 0).
static func _at(hour: int, minute: int = 0) -> int:
	for tk in GameTime.TICKS_PER_DAY:
		if GameTime.hour(tk) == hour and GameTime.minute(tk) == minute:
			return tk
	return 0


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
	assert_eq(e.farming.load_snapshot(s["farming"]), 0)
	assert_eq(e.kitchens.load_snapshot(s["kitchens"]), 0)
	assert_eq(e.col.load_snapshot(s["col"]), 0)
	assert_eq(e.jobs.load_snapshot(s["jobs"]), 0)
	e.rooms.rebuild_all()
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


func test_round_trip_mid_eat_sleep_cook_and_collapsed() -> void:
	t = _at(6)
	var e := Env.new(FS.make_grid(reg, Vector2i(40, 30)))
	var eater := e.col.spawn_npc(Vector2i(5, 9))
	var sleeper := e.col.spawn_npc(Vector2i(30, 9))
	var cook := e.col.spawn_npc(Vector2i(14, 9))
	var down := e.col.spawn_npc(Vector2i(36, 9))
	for w in Npc.WORK_KEYS:
		e.col.set_work_enabled(eater.id, w, false)
		e.col.set_work_enabled(sleeper.id, w, false)
		e.col.set_work_enabled(cook.id, w, w == &"cook")
	var bed: String = e.bld.place(&"bed", Vector2i(32, 9), {&"dirt": 50.0}).data["id"]
	e.col.assign_bed(sleeper.id, bed)
	var kid: String = e.bld.place(&"kitchen", Vector2i(16, 9), {&"rock": 100.0}).data["id"]
	e.inv.spawn_ground(&"mushroom", 2.0, Vector2i(18, 9))
	e.inv.spawn_ground(&"ration", 4.0, Vector2i(2, 9))
	eater.hunger = 30.0
	sleeper.stamina = 5.0  # exhausted: sleeps now
	down.hunger = 0.0
	down.health = 0.01
	for w in Npc.WORK_KEYS:
		e.col.set_work_enabled(down.id, w, false)
	var ok := _run(e, 400, func() -> bool:
		var cj := e.jobs.get_job(cook.job_id)
		return e.inv.carried_by(eater.id) != null and eater._activity == &"eat" \
				and sleeper._phase == &"asleep" and cj != null and cj.phase == Job.PHASE_WORK \
				and cj.work_ticks > 5)
	assert_true(ok, "eater %s %s %s carry %s; sleeper %s %s; cook %s %s" % [eater._activity, eater._phase,
			eater.state, e.inv.carried_by(eater.id), sleeper._activity, sleeper._phase, cook.job_id,
			e.jobs.describe_job(cook.job_id)])
	assert_eq(down.condition, Npc.CONDITION_COLLAPSED, "down: hunger %.2f health %.2f stamina %.2f %s" % [
			down.hunger, down.health, down.stamina, down.state])
	var meal_item := e.inv.carried_by(eater.id).id
	var cook_job := cook.job_id
	var cook_ticks := e.jobs.get_job(cook_job).work_ticks
	var totals := e.inv.total_kg_by_material()
	var needs := {}
	for n in e.col.all_npcs():
		needs[n.id] = [n.hunger, n.stamina, n.health, n.condition]

	var s := e.snapshot()
	var e2 := _load(s)
	assert_eq(e2.jobs.check_invariants(), [] as Array[String])
	assert_eq(e2.inv.check_conservation(), [] as Array[String])
	assert_eq(e2.inv.total_kg_by_material(), totals, "no food duplicated or lost")
	for n in e2.col.all_npcs():
		assert_eq([n.hunger, n.stamina, n.health, n.condition], needs[n.id], "%s needs kept" % n.id)
	var eater2 := e2.col.get_npc(eater.id)
	assert_eq(eater2._activity, &"eat")
	assert_eq(eater2._food_item, meal_item)
	assert_eq(e2.inv.carried_by(eater.id).id, meal_item)
	var sleeper2 := e2.col.get_npc(sleeper.id)
	assert_eq(sleeper2._phase, &"asleep")
	assert_true(sleeper2._in_bed)
	assert_eq(sleeper2.bed_id, bed)
	assert_eq(e2.col.get_npc(cook.id).job_id, cook_job)
	assert_eq(e2.jobs.get_job(cook_job).work_ticks, cook_ticks)
	assert_almost_eq(e2.inv.site_kg(cook_job), 2.0, 0.001)
	assert_eq(e2.col.get_npc(down.id).condition, Npc.CONDITION_COLLAPSED)
	# Everything finishes after load (everyone may work now: someone feeds the collapsed NPC).
	for n in e2.col.all_npcs():
		for w in Npc.WORK_KEYS:
			e2.col.set_work_enabled(n.id, w, true)
	var down2 := e2.col.get_npc(down.id)
	var seen := [false, false]
	var done := _run(e2, 3000, func() -> bool:
		seen[0] = seen[0] or eater2.hunger > 90.0  # finished the meal it carried
		seen[1] = seen[1] or e2.inv.total_kg_by_material().get(&"meal", 0.0) > 0.0  # cooked
		return seen[0] and seen[1] and down2.is_ok())
	assert_true(done, "eater %.1f meal %s down %s h%.1f hp%.1f; jobs %s" % [eater2.hunger,
			e2.inv.total_kg_by_material(), down2.condition, down2.hunger, down2.health,
			e2.jobs.all_jobs().map(func(j: Job) -> String: return e2.jobs.describe_job(j.id))])
	assert_eq(e2.col.deaths(), 0)
	assert_ne(kid, "")


func test_m3_colony_snapshot_loads_fed_and_rested() -> void:
	var e := Env.new(FS.make_grid(reg, Vector2i(40, 30)))
	e.col.spawn_npc(Vector2i(5, 9))
	var s := e.col.to_snapshot()
	for d: Dictionary in s["npcs"]:
		for k in ["hunger", "stamina", "health", "condition", "schedule", "bed_id", "activity",
				"phase", "food_item", "eat_ticks", "table_id", "in_bed", "collapsed_since"]:
			d.erase(k)
		(d["work_enabled"] as Dictionary).erase("farm")
		(d["work_enabled"] as Dictionary).erase("cook")
	var e2 := Env.new(FS.make_grid(reg, Vector2i(40, 30)))
	assert_eq(e2.col.load_snapshot(bytes_to_var(var_to_bytes(s))), 0)
	var n: Npc = e2.col.all_npcs()[0]
	assert_eq([n.hunger, n.stamina, n.health], [100.0, 100.0, 100.0])
	assert_eq(n.condition, Npc.CONDITION_OK)
	assert_eq(n.schedule, Npc.default_schedule())
	assert_true(n.work_enabled[&"farm"] and n.work_enabled[&"cook"])
