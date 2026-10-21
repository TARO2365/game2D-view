extends GutTest
## M4a acceptance runs (plan §4):
## 4.2 a small base (2 farm plots, kitchen, table, 3 beds, crate, 20 kg of
##     rations) keeps 3 NPCs alive for 10 in-game days (60 000 ticks)
##     unattended; invariants + kg conservation (food included) every 500 ticks.
## 4.1 without farms the food runs out, NPCs collapse with alerts, and
##     feeding them (a rescuer arrives with food) brings them back.
## World 60x30: rows < 10 air, dirt below, bedrock bottom (feet row 9).

const SIZE := Vector2i(60, 30)
const H := GameTime.TICKS_PER_HOUR
const DAY := GameTime.TICKS_PER_DAY
const CHECK_EVERY := 500

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


func _setup() -> void:
	g = WorldGrid.new(SIZE.x, SIZE.y, reg)
	var tl := PackedByteArray()
	tl.resize(SIZE.x * SIZE.y)
	for y in SIZE.y:
		for x in SIZE.x:
			tl[y * SIZE.x + x] = TileRegistry.BEDROCK if y == SIZE.y - 1 \
					else (TileRegistry.DIRT if y >= 10 else TileRegistry.AIR)
	g.tiles = tl
	for x in SIZE.x:
		g.surface_y[x] = 10
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
	col = Colony.new(g, nav, jobs, ids, 2026)
	alerts = AlertService.new()
	col.attach_m4a(alerts, rooms)
	t = 6 * H


## Advances one tick in session order; false (and a test failure) on a broken invariant.
func _tick(check: bool) -> bool:
	t += 1
	alerts.current_tick = t
	farming.update(t)
	jobs.update(t)
	col.update(t)
	if check:
		var errs := jobs.check_invariants()
		errs.append_array(inv.check_conservation())
		if not errs.is_empty():
			fail_test("tick %d: %s" % [t, errs.slice(0, 5)])
			return false
	return true


func _food() -> Dictionary:
	var tot := inv.total_kg_by_material()
	return {"ration": snappedf(float(tot.get(&"ration", 0.0)), 0.1),
			"mushroom": snappedf(float(tot.get(&"mushroom", 0.0)), 0.1),
			"meal": snappedf(float(tot.get(&"meal", 0.0)), 0.1)}


func test_ten_days_with_farms_and_kitchen() -> void:
	_setup()
	for x in [20, 23]:
		bld.place(&"farm_plot", Vector2i(x, 9), {&"dirt": 50.0})
	bld.place(&"kitchen", Vector2i(27, 9), {&"rock": 100.0})
	bld.place(&"table", Vector2i(31, 9), {&"rock": 50.0})
	for x in [36, 39, 42]:
		bld.place(&"bed", Vector2i(x, 9), {&"dirt": 50.0})
	bld.place(&"crate", Vector2i(46, 9), {&"dirt": 50.0})
	inv.spawn_ground(&"ration", 20.0, Vector2i(33, 9))
	for x in [28, 30, 32]:
		col.spawn_npc(Vector2i(x, 9))
	var daily: Array = []
	var min_hunger := 100.0
	var min_health := 100.0
	var collapses := 0
	for i in 10 * DAY:
		if not _tick(t % CHECK_EVERY == 0):
			return
		for n in col.all_npcs():
			min_hunger = minf(min_hunger, n.hunger)
			min_health = minf(min_health, n.health)
			if not n.is_ok():
				collapses += 1
		if (t - 6 * H) % DAY == 0:
			daily.append("day %d %s" % [GameTime.day(t), _food()])
	gut.p("food by day: %s" % [daily])
	gut.p("lowest hunger %.1f, lowest health %.1f, eaten %s" % [min_hunger, min_health,
			inv.consumed_kg_by_material()])
	assert_eq(col.deaths(), 0, "nobody died")
	assert_eq(col.count(), 3)
	assert_eq(collapses, 0, "nobody collapsed")
	assert_gt(float(inv.consumed_kg_by_material().get(&"meal", 0.0)), 0.0, "meals cooked and eaten")
	assert_gt(float(inv.consumed_kg_by_material().get(&"mushroom", 0.0)), 0.0, "mushrooms grown and used")
	var owned := {}
	for n in col.all_npcs():
		assert_false(n.bed_id.is_empty(), "%s owns a bed" % n.id)
		owned[n.bed_id] = true
	assert_eq(owned.size(), 3)
	assert_eq(jobs.check_invariants(), [] as Array[String])
	assert_eq(inv.check_conservation(), [] as Array[String])


func test_starvation_collapse_and_rescue() -> void:
	_setup()
	inv.spawn_ground(&"ration", 3.0, Vector2i(30, 9))
	var colonists: Array[Npc] = []
	for x in [28, 30, 32]:
		colonists.append(col.spawn_npc(Vector2i(x, 9)))
	var no_food_seen := [false]
	var ok := false
	for i in 4 * DAY:
		if not _tick(t % CHECK_EVERY == 0):
			return
		no_food_seen[0] = no_food_seen[0] or alerts.has_alert("colony/no_food")
		var down := false
		for n in colonists:
			down = down or not n.is_ok()
		if down:
			ok = true
			break
	assert_true(ok, "colonists collapse once the rations run out")
	assert_true(no_food_seen[0], "no-food alert raised")
	var first_down := 0
	for n in colonists:
		if not n.is_ok():
			first_down += 1
			assert_true(alerts.has_alert(n.id + "/collapsed"), "collapse alert for %s" % n.id)
	assert_eq(col.deaths(), 0, "collapse first, no instant death")
	gut.p("first collapse at %s (%d down)" % [GameTime.label(t), first_down])
	# A rescuer arrives with food (working all hours): it feeds every collapsed
	# colonist and they get up.
	var rescuer := col.spawn_npc(Vector2i(10, 9))
	var all_work := PackedByteArray()
	all_work.resize(24)
	all_work.fill(Npc.Activity.WORK)
	col.set_schedule(rescuer.id, all_work)
	inv.spawn_ground(&"ration", 20.0, Vector2i(12, 9))
	var recovered := false
	var collapsed_ever := {}
	for i in 2 * DAY:
		if not _tick(t % CHECK_EVERY == 0):
			return
		var up := true
		for n in colonists:
			if not n.is_ok():
				collapsed_ever[n.id] = true
			up = up and n.is_ok()
		if up and i > DAY / 2:
			recovered = true
			break
	gut.p("collapsed and recovered: %d colonist(s), ends %s" % [collapsed_ever.size(), GameTime.label(t)])
	assert_true(recovered, "fed colonists recover")
	assert_eq(col.deaths(), 0)
	assert_gt(float(inv.consumed_kg_by_material().get(&"ration", 0.0)), 3.0)
