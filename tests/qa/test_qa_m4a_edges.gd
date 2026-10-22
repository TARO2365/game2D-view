extends GutTest
## QA M4a edge cases: furniture removed mid-use, farm plot losing its soil
## mid-growth, kitchen removed mid-cook, food in filtered crates, food out of
## reach of a confined NPC, a collapsed NPC falling. Invariants every tick
## (jobs, kg conservation incl. food, QA M2/M3/M4a).
## Grid 48x32: rows < 10 air, dirt below, bedrock bottom (feet row 9).

const ENV := preload("res://tools/qa_m3_env.gd")
const K := DesignationMap.Kind
const DAY := GameTime.TICKS_PER_DAY

var reg: TileRegistry
var e: Variant
var s: WorldSession


func before_all() -> void:
	reg = TileRegistry.load_default()


func before_each() -> void:
	e = ENV.new(reg)
	s = e.ses


func _ok(ticks: int, cond: Callable, msg: String) -> bool:
	var ok: bool = e.run(ticks, cond)
	assert_eq(e.errors, [] as Array[String], "invariants (%s)" % msg)
	assert_true(ok, "%s; jobs: %s" % [msg, e.jobs_text()])
	return ok and e.errors.is_empty()


func _food_ledger() -> float:
	var tot := 0.0
	for m: StringName in [&"ration", &"meal", &"mushroom"]:
		tot += e.kg(m) + float(e.ses.inventory.consumed_kg_by_material().get(m, 0.0))
	return tot


# --- Furniture removed mid-use ------------------------------------------------

func test_bed_deconstructed_mid_sleep_then_floor_sleep_and_save_load() -> void:
	var sleeper := s.colony.spawn_npc(Vector2i(6, 9))
	var worker := s.colony.spawn_npc(Vector2i(20, 9))
	var bed: String = s.buildings.place(&"bed", Vector2i(10, 9), {&"dirt": 50.0}).data["id"]
	s.inventory.spawn_ground(&"ration", 10.0, Vector2i(4, 9))
	sleeper.stamina = 10.0   # exhausted: sleeps now
	worker.stamina = 100.0
	if not _ok(300, func() -> bool: return sleeper._phase == &"asleep" and sleeper._in_bed, "asleep in bed"):
		return
	assert_true(s.designations.designate(Rect2i(10, 9, 2, 1), K.DECONSTRUCT, 9).ok)
	if not _ok(600, func() -> bool: return e.ses.buildings.count() == 0, "bed deconstructed under the sleeper"):
		return
	var sl: Npc = e.ses.colony.get_npc(sleeper.id)
	assert_eq(sl.bed_id, "", "ownership cleared")
	assert_eq(sl._activity, &"sleep", "keeps sleeping")
	assert_false(sl._in_bed, "now on the floor")
	assert_eq(e.reload(), [] as Array[String], "save/load while sleeping on the floor")
	_ok(DAY, func() -> bool: return e.ses.colony.get_npc(sleeper.id).stamina > 99.0, "recovers on the floor")
	assert_almost_eq(e.kg(&"dirt"), 50.0, 0.001, "bed refunded once")


func test_bed_lost_while_walking_to_it_with_save_load() -> void:
	var n := s.colony.spawn_npc(Vector2i(4, 9))
	s.buildings.place(&"bed", Vector2i(30, 9), {&"dirt": 50.0})
	s.inventory.spawn_ground(&"ration", 10.0, Vector2i(5, 9))
	n.stamina = 10.0
	if not _ok(100, func() -> bool: return n._activity == &"sleep" and n._phase == &"go" and n.is_moving(), "walking to bed"):
		return
	assert_eq(e.reload(), [] as Array[String], "save/load while walking to bed")
	e.ses.grid.apply_edit(Rect2i(30, 10, 2, 1), WorldGrid.Edit.DIG)   # floor gone -> bed lost
	assert_eq(e.ses.buildings.count(), 0)
	_ok(400, func() -> bool:
		var m: Npc = e.ses.colony.get_npc(n.id)
		return m._phase == &"asleep" and not m._in_bed, "sleeps on the floor instead")


func test_table_deconstructed_mid_eat() -> void:
	var n := s.colony.spawn_npc(Vector2i(6, 9))
	s.colony.spawn_npc(Vector2i(16, 9))
	var tid: String = s.buildings.place(&"table", Vector2i(10, 9), {&"rock": 50.0}).data["id"]
	s.inventory.spawn_ground(&"meal", 4.0, Vector2i(4, 9))
	n.hunger = 20.0
	var before: float = _food_ledger()
	if not _ok(300, func() -> bool: return n._activity == &"eat" and n._table_id == tid and n._phase == &"eating", "eating at the table"):
		return
	assert_true(s.designations.designate(Rect2i(10, 9, 2, 1), K.DECONSTRUCT, 9).ok)
	if not _ok(300, func() -> bool: return e.ses.buildings.count() == 0, "table removed"):
		return
	_ok(300, func() -> bool: return n._activity == &"", "meal finished")
	assert_gt(n.hunger, 60.0, "fed despite losing the table")
	assert_almost_eq(_food_ledger(), before, 0.001, "food kg conserved")
	assert_eq(e.ses.colony._table_users.size(), 0, "no stale table user")


# --- Farm and kitchen ----------------------------------------------------------

func test_farm_loses_soil_mid_growth() -> void:
	s.colony.spawn_npc(Vector2i(6, 9))
	s.inventory.spawn_ground(&"ration", 10.0, Vector2i(4, 9))
	var fid: String = s.buildings.place(&"farm_plot", Vector2i(14, 9), {&"dirt": 50.0}).data["id"]
	if not _ok(1500, func() -> bool: return e.ses.farming.stage(fid) == Farming.Stage.GROWING, "planted"):
		return
	e.run(1000)
	s.grid.apply_edit(Rect2i(14, 10, 1, 1), WorldGrid.Edit.DIG)   # half of its soil
	assert_eq(s.buildings.count(), 0, "farm lost")
	assert_eq(s.farming.farm_ids().size(), 0)
	assert_eq(e.check(), [] as Array[String])
	e.run(DAY + 100)
	assert_eq(e.errors, [] as Array[String])
	assert_almost_eq(float(s.inventory.spawned_kg_by_material().get(&"mushroom", 0.0)), 0.0, 0.001, "no crop from a lost farm")
	for j in s.jobs.all_jobs():
		assert_ne(j.kind, Job.KIND_FARM, "no farm job left")


## The kitchen vanishes (floor dug out) halfway through cooking: the input
## on the site goes back to the ground, no meal appears, the cook is free.
func test_kitchen_lost_mid_cook() -> void:
	s.colony.spawn_npc(Vector2i(6, 9))
	s.inventory.spawn_ground(&"ration", 10.0, Vector2i(4, 9))
	s.buildings.place(&"kitchen", Vector2i(14, 9), {&"rock": 100.0})
	s.inventory.spawn_ground(&"mushroom", 2.0, Vector2i(8, 9))
	if not _ok(1500, func() -> bool:
		for j in e.ses.jobs.all_jobs():
			if j.kind == Job.KIND_COOK and j.phase == Job.PHASE_WORK and j.work_ticks > 5:
				return true
		return false, "cooking"):
		return
	assert_almost_eq(e.ses.inventory.site_kg(e.ses.jobs.all_jobs()[0].id) if e.ses.jobs.job_count() > 0 else 0.0, 2.0, 0.001, "input on the site")
	s.grid.apply_edit(Rect2i(14, 10, 1, 1), WorldGrid.Edit.DIG)   # kitchen loses its floor
	assert_eq(s.buildings.count(), 0)
	assert_eq(e.check(), [] as Array[String], "no leak right after the loss")
	e.run(100)
	assert_eq(e.errors, [] as Array[String])
	assert_almost_eq(e.kg(&"meal"), 0.0, 0.001, "no meal from an interrupted cook")
	assert_almost_eq(e.kg(&"mushroom") + float(e.ses.inventory.consumed_kg_by_material().get(&"mushroom", 0.0)), 2.0, 0.001,
			"mushroom back (or eaten), nothing lost or created")
	assert_almost_eq(e.kg(&"rock"), 100.0, 0.001, "kitchen refunded")
	for n in e.ses.colony.all_npcs():
		assert_eq(n.job_id, "", "cook released")


# --- Food storage and reach ---------------------------------------------------

func test_food_in_filtered_crates_eaten_from_crate() -> void:
	var n := s.colony.spawn_npc(Vector2i(6, 9))
	var meal_crate: String = s.buildings.place(&"crate", Vector2i(20, 9), {&"rock": 50.0}).data["id"]
	assert_true(s.crates.set_filter(meal_crate, [&"meal"] as Array[StringName]).ok)
	s.stockpiles.designate(Rect2i(30, 9, 2, 1))
	s.inventory.spawn_ground(&"meal", 6.0, Vector2i(10, 9))
	s.inventory.spawn_ground(&"mushroom", 6.0, Vector2i(12, 9))
	n.hunger = 90.0
	if not _ok(2000, func() -> bool:
		return e.ses.inventory.crate_kg(meal_crate) > 5.99 \
				and e.ses.inventory.ground_kg_at(Vector2i(30, 9)) + e.ses.inventory.ground_kg_at(Vector2i(31, 9)) > 5.99,
			"meal in the meal crate, mushrooms in the zone"):
		return
	for it in e.ses.inventory.crate_items(meal_crate):
		assert_eq(it.material, &"meal")
	n.hunger = 30.0
	_ok(600, func() -> bool: return n.hunger > 70.0, "ate a meal taken from the crate")
	assert_lt(e.ses.inventory.crate_kg(meal_crate), 6.0, "meal came out of the crate")


## The only food is out of a confined NPC's reach: it must not spin on it
## (path budget) and must not keep it reserved from others.
func test_food_unreachable_for_confined_npc() -> void:
	s.grid.apply_edit(Rect2i(10, 10, 3, 5), WorldGrid.Edit.DIG)   # 5-deep pit, no ladder
	var trapped := s.colony.spawn_npc(Vector2i(11, 14))
	var free_npc := s.colony.spawn_npc(Vector2i(30, 9))
	s.inventory.spawn_ground(&"meal", 2.0, Vector2i(25, 9))
	trapped.hunger = 35.0
	free_npc.hunger = 100.0
	var s0 := s.nav.searches_total
	e.run(1000)
	assert_eq(e.errors, [] as Array[String])
	var searches := s.nav.searches_total - s0
	gut.p("confined hungry NPC: %d path searches in 1000 ticks, hunger %.1f, food item '%s'" % [searches, trapped.hunger, trapped._food_item])
	assert_lt(searches, 60, "no search spin on unreachable food")
	assert_eq(trapped._food_item, "", "does not keep the food reserved")
	free_npc.hunger = 30.0
	_ok(400, func() -> bool: return free_npc.hunger > 60.0, "the free NPC can eat it")


func test_collapsed_npc_falls_and_feed_job_follows() -> void:
	var a := s.colony.spawn_npc(Vector2i(14, 9))
	s.colony.spawn_npc(Vector2i(30, 9))
	a.hunger = 0.0
	a.health = 0.5
	if not _ok(200, func() -> bool: return not a.is_ok(), "A collapses"):
		return
	s.grid.apply_edit(Rect2i(13, 10, 3, 3), WorldGrid.Edit.DIG)   # floor gone: A falls 3 tiles
	s.grid.apply_structure(Vector2i(13, 12), WorldGrid.Structure.LADDER)
	s.grid.apply_structure(Vector2i(13, 11), WorldGrid.Structure.LADDER)
	s.grid.apply_structure(Vector2i(13, 10), WorldGrid.Structure.LADDER)
	s.inventory.spawn_ground(&"meal", 3.0, Vector2i(25, 9))
	_ok(2000, func() -> bool: return a.hunger > 50.0, "fed at its new place")
	assert_eq(a.tile.y, 12, "lies on the pit floor")
