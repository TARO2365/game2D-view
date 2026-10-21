extends GutTest
## M4a Colony: needs, schedules, eating (food choice, tables), sleeping
## (beds, floor), pre-emption order, collapse / feeding / death, alerts,
## farm and cook jobs. Grid 40x30 from fs_util.make_grid: rows < 10 air,
## dirt below (surface feet row 9). Ticks start at 06:00 unless a test says
## otherwise (tick 0 is midnight: sleep time in the default schedule).

const FS := preload("res://tests/helpers/fs_util.gd")
const K := DesignationMap.Kind
const H := GameTime.TICKS_PER_HOUR

var reg: TileRegistry
var g: WorldGrid
var ids: StableIdAllocator
var bld: Buildings
var des: DesignationMap
var inv: Inventory
var sp: StockpileZones
var rooms: RoomMap
var mats: MaterialDefs
var crates: CrateStorage
var farming: Farming
var kitchens: Kitchens
var orders: BuildOrders
var nav: NavGrid
var jobs: JobManager
var col: Colony
var alerts: AlertService
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
	mats = MaterialDefs.load_default()
	crates = CrateStorage.new(bld, inv, mats)
	farming = Farming.new(bld, inv, ids)
	kitchens = Kitchens.new(bld, inv)
	orders = BuildOrders.new(g, bld, des, ids)
	nav = NavGrid.new(g, 3)
	jobs = JobManager.new(g, des, inv, sp, nav, ids, bld, crates, orders)
	jobs.attach_m4a(mats, farming, kitchens)
	col = Colony.new(g, nav, jobs, ids, 42)
	alerts = AlertService.new()
	col.attach_m4a(alerts, rooms)
	t = 6 * H  # 06:00


func _run(max_ticks: int, cond: Callable = Callable()) -> bool:
	for i in max_ticks:
		t += 1
		alerts.current_tick = t
		farming.update(t)
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


func _kg(m: StringName) -> float:
	return float(inv.total_kg_by_material().get(m, 0.0))


func _eaten(m: StringName) -> float:
	return float(inv.consumed_kg_by_material().get(m, 0.0))


# --- Needs and schedule ------------------------------------------------------

func test_needs_decay_while_working_hours() -> void:
	var n := col.spawn_npc(Vector2i(5, 9))
	_run(600)
	assert_almost_eq(n.hunger, 90.0, 0.2, "-100 per day")
	assert_almost_eq(n.stamina, 85.0, 0.2, "-100 per 16 h awake")
	assert_almost_eq(n.health, 100.0, 0.001)
	assert_eq(n.state, &"idle")


func test_schedule_api_and_free_time_takes_no_jobs() -> void:
	var n := col.spawn_npc(Vector2i(5, 9))
	var bad := PackedByteArray([0, 1])
	assert_eq(col.set_schedule(n.id, bad).code, &"invalid_schedule")
	var free := PackedByteArray()
	free.resize(24)
	free.fill(Npc.Activity.FREE)
	assert_true(col.set_schedule_all(free).ok)
	des.designate(Rect2i(8, 10, 1, 1), K.DIG)
	_run(100)
	assert_eq(n.job_id, "", "free time: no jobs")
	var work := Npc.default_schedule()
	assert_true(col.set_schedule(n.id, work).ok)
	assert_true(_run(200, func() -> bool: return g.get_tile(Vector2i(8, 10)) == TileRegistry.AIR))
	assert_eq(col.set_schedule("npc:99", work).code, &"unknown_npc")


# --- Eating --------------------------------------------------------------------

func test_hungry_npc_eats_preferring_meal() -> void:
	var n := col.spawn_npc(Vector2i(5, 9))
	n.hunger = 30.0
	inv.spawn_ground(&"ration", 5.0, Vector2i(8, 9))
	inv.spawn_ground(&"meal", 5.0, Vector2i(14, 9))
	assert_true(_run(300, func() -> bool: return n.hunger > 90.0))
	assert_gt(_eaten(&"meal"), 1.0, "meal preferred over a nearer ration")
	assert_almost_eq(_eaten(&"ration"), 0.0, 0.001)
	assert_almost_eq(_eaten(&"meal") * 60.0, 70.0, 1.5, "ate just enough to be full")
	assert_eq(n._activity, &"")
	assert_eq(n._food_item, "")


func test_eats_at_a_free_table() -> void:
	var n := col.spawn_npc(Vector2i(5, 9))
	n.hunger = 30.0
	bld.place(&"table", Vector2i(20, 9), {&"rock": 50.0})
	inv.spawn_ground(&"ration", 5.0, Vector2i(8, 9))
	var at_table := [false]
	assert_true(_run(400, func() -> bool:
		if n._phase == &"eating" and not n._table_id.is_empty():
			at_table[0] = true
		return n.hunger > 90.0))
	assert_true(at_table[0], "walked to the table to eat")


func test_food_from_crate() -> void:
	var n := col.spawn_npc(Vector2i(5, 9))
	n.hunger = 20.0
	var cid: String = bld.place(&"crate", Vector2i(12, 9), {&"dirt": 50.0}).data["id"]
	var iid := inv.spawn_ground(&"ration", 10.0, Vector2i(0, 9))
	inv.pick_up(iid, "npc:999", 10.0)
	inv.store_in_crate("npc:999", cid)
	assert_true(_run(300, func() -> bool: return n.hunger > 90.0))
	assert_almost_eq(inv.crate_kg(cid), 10.0 - 80.0 / 50.0, 0.05)


func test_critical_hunger_preempts_work() -> void:
	var n := col.spawn_npc(Vector2i(5, 9))
	inv.spawn_ground(&"ration", 5.0, Vector2i(3, 9))
	des.designate(Rect2i(30, 10, 1, 1), K.DIG)
	assert_true(_run(50, func() -> bool: return not n.job_id.is_empty()))
	var jid := n.job_id
	n.hunger = 5.0
	_run(NavGrid.TICKS_PER_STEP + 1)  # decided at the next step boundary
	assert_eq(n.job_id, "", "job released for eating")
	assert_eq(jobs.get_job(jid).worker_id, "")
	assert_eq(n._activity, &"eat")
	assert_true(_run(300, func() -> bool: return n.hunger > 90.0))
	assert_true(_run(800, func() -> bool: return g.get_tile(Vector2i(30, 10)) == TileRegistry.AIR),
			"back to work after eating")


func test_no_food_raises_alert_and_npc_keeps_working() -> void:
	var n := col.spawn_npc(Vector2i(5, 9))
	n.hunger = 30.0
	des.designate(Rect2i(8, 10, 1, 1), K.DIG)
	assert_true(_run(200, func() -> bool: return g.get_tile(Vector2i(8, 10)) == TileRegistry.AIR))
	assert_true(alerts.has_alert("colony/no_food"))
	assert_true(alerts.has_alert(n.id + "/hungry"))
	inv.spawn_ground(&"ration", 5.0, Vector2i(3, 9))
	assert_true(_run(300, func() -> bool: return n.hunger > 90.0))
	_run(25)
	assert_false(alerts.has_alert(n.id + "/hungry"), "cleared when fed")


# --- Sleeping ------------------------------------------------------------------

func test_sleeps_in_own_bed_at_night_and_wakes() -> void:
	t = 21 * H + H / 2  # 21:30
	var n := col.spawn_npc(Vector2i(5, 9))
	n.stamina = 50.0
	var bed: String = bld.place(&"bed", Vector2i(15, 9), {&"dirt": 50.0}).data["id"]
	_run(1)
	assert_true(_run(20 * 60, func() -> bool: return n.state == &"sleeping"))
	assert_eq(n.bed_id, bed, "auto-assigned")
	assert_true(n._in_bed)
	assert_true(n.tile == Vector2i(15, 9) or n.tile == Vector2i(16, 9))
	var s0 := n.stamina
	_run(H)
	assert_almost_eq(n.stamina - s0, 100.0 / 6.0, 0.5, "+100 per 6 h in a bed")
	# Asleep until 06:00 even when rested; then awake.
	assert_true(_run(10 * H, func() -> bool: return n._activity != &"sleep"))
	assert_eq(GameTime.hour(t), 6)
	assert_almost_eq(n.stamina, 100.0, 0.001)


func test_exhausted_sleeps_on_the_floor_by_day() -> void:
	var n := col.spawn_npc(Vector2i(5, 9))
	n.stamina = 10.0
	_run(2)
	assert_eq(n.state, &"sleeping")
	assert_false(n._in_bed)
	var s0 := n.stamina
	_run(H)
	assert_almost_eq(n.stamina - s0, 100.0 / 6.0 * 0.5, 0.5, "floor: half rate")
	assert_true(_run(20 * H, func() -> bool: return n._activity == &""), "wakes when rested")
	assert_almost_eq(n.stamina, 100.0, 0.5)


func test_bed_ownership_unique_and_assign_bed() -> void:
	var a := col.spawn_npc(Vector2i(5, 9))
	var b := col.spawn_npc(Vector2i(6, 9))
	var c := col.spawn_npc(Vector2i(7, 9))
	var bed1: String = bld.place(&"bed", Vector2i(15, 9), {&"dirt": 50.0}).data["id"]
	var bed2: String = bld.place(&"bed", Vector2i(20, 9), {&"dirt": 50.0}).data["id"]
	_run(40)
	var owners := {}
	for n in [a, b, c]:
		if not (n as Npc).bed_id.is_empty():
			assert_false(owners.has(n.bed_id), "unique owners")
			owners[n.bed_id] = true
	assert_eq(owners.size(), 2)
	assert_true(alerts.has_alert("colony/no_free_bed"))
	var bedless: Npc = a if a.bed_id.is_empty() else (b if b.bed_id.is_empty() else c)
	assert_true(col.assign_bed(bedless.id, bed1).ok)
	assert_eq(bedless.bed_id, bed1)
	assert_eq(col.assign_bed(a.id, "bld:999").code, &"not_bed")
	assert_eq(jobs.check_invariants(), [] as Array[String])
	bld.place(&"bed", Vector2i(25, 9), {&"dirt": 50.0})
	_run(40)
	assert_false(alerts.has_alert("colony/no_free_bed"))
	assert_ne(bed2, "")


# --- Collapse, feeding, death ----------------------------------------------------

func test_collapse_feed_and_recover() -> void:
	var patient := col.spawn_npc(Vector2i(5, 9))
	var helper := col.spawn_npc(Vector2i(20, 9))
	patient.hunger = 0.0
	patient.health = 0.01
	_run(2)
	assert_eq(patient.condition, Npc.CONDITION_COLLAPSED)
	assert_eq(patient.state, &"collapsed")
	assert_true(alerts.has_alert(patient.id + "/collapsed"))
	assert_eq(col.command_move(patient.id, Vector2i(10, 9)).code, &"collapsed")
	assert_eq(col.command_stop(patient.id).code, &"collapsed")
	inv.spawn_ground(&"ration", 5.0, Vector2i(25, 9))
	assert_true(_run(400, func() -> bool: return patient.hunger > 50.0), "fed by the helper")
	assert_gt(_eaten(&"ration"), 1.0)
	assert_true(_run(2000, func() -> bool: return patient.is_ok()), "gets up when health > 20")
	_run(25)
	assert_false(alerts.has_alert(patient.id + "/collapsed"))
	assert_ne(helper.id, patient.id)


func test_death_after_collapse_without_food() -> void:
	var n := col.spawn_npc(Vector2i(5, 9))
	inv.spawn_ground(&"rock", 50.0, Vector2i(6, 9))
	n.hunger = 0.0
	n.health = 0.01
	_run(2)
	assert_eq(n.condition, Npc.CONDITION_COLLAPSED)
	assert_true(_run(Colony.DEATH_TICKS + 10, func() -> bool: return col.get_npc(n.id) == null))
	assert_eq(col.deaths(), 1)
	assert_eq(n.condition, Npc.CONDITION_DEAD)
	assert_true(alerts.has_alert(n.id + "/died"))
	assert_false(alerts.has_alert(n.id + "/collapsed"))
	assert_eq(inv.check_conservation(), [] as Array[String])
	assert_eq(jobs.check_invariants(), [] as Array[String])


# --- Farm and cook jobs --------------------------------------------------------

func test_farm_plant_and_harvest() -> void:
	col.spawn_npc(Vector2i(5, 9))
	var fid: String = bld.place(&"farm_plot", Vector2i(12, 9), {&"dirt": 50.0}).data["id"]
	assert_eq(jobs.job_count(), 1, "plant job")
	assert_true(_run(300, func() -> bool: return farming.stage(fid) == Farming.Stage.GROWING))
	assert_eq(jobs.job_count(), 0)
	farming.update(t + Farming.GROW_TICKS)  # a day later
	t += Farming.GROW_TICKS
	assert_eq(farming.stage(fid), Farming.Stage.READY)
	_run(1)
	assert_eq(jobs.job_count(), 1, "harvest job")
	assert_true(_run(300, func() -> bool: return _kg(&"mushroom") > 0.0))
	assert_almost_eq(_kg(&"mushroom"), Farming.YIELD_KG, 0.001)
	assert_true(_run(300, func() -> bool: return farming.stage(fid) == Farming.Stage.GROWING), "replanted")


func test_cook_meals_up_to_target() -> void:
	col.spawn_npc(Vector2i(5, 9))
	var kid: String = bld.place(&"kitchen", Vector2i(12, 9), {&"rock": 100.0}).data["id"]
	kitchens.set_target_kg(kid, 4.0)
	inv.spawn_ground(&"mushroom", 10.0, Vector2i(3, 9))
	assert_true(_run(1500, func() -> bool: return _kg(&"meal") >= 4.0 and jobs.job_count() == 0))
	assert_almost_eq(_kg(&"meal"), 4.0, 0.001, "stops at the target")
	assert_almost_eq(_kg(&"mushroom"), 6.0, 0.001)
	assert_almost_eq(_eaten(&"mushroom"), 4.0, 0.001)


func test_work_toggles_farm_and_cook() -> void:
	var n := col.spawn_npc(Vector2i(5, 9))
	assert_true(col.set_work_enabled(n.id, &"farm", false).ok)
	var fid: String = bld.place(&"farm_plot", Vector2i(12, 9), {&"dirt": 50.0}).data["id"]
	_run(200)
	assert_eq(farming.stage(fid), Farming.Stage.EMPTY, "farming disabled")
	col.set_work_enabled(n.id, &"farm", true)
	assert_true(_run(300, func() -> bool: return farming.stage(fid) == Farming.Stage.GROWING))
