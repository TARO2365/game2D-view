extends GutTest
## QA M4a: starvation, collapse, rescue, death; pre-emption of every job
## phase by a need; schedules and GameTime boundaries; alerts incl. after
## load. Grid 48x32: rows < 10 air, dirt below, bedrock bottom (feet row 9).

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


func _alert_keys() -> Array[String]:
	var out: Array[String] = []
	for a in e.ses.alerts.alerts():
		out.append(a["key"])
	return out


# --- Starvation, collapse, rescue ---------------------------------------------

func test_collapse_alerts_survive_load_then_rescue_by_feeding() -> void:
	var a := s.colony.spawn_npc(Vector2i(10, 9))
	var b := s.colony.spawn_npc(Vector2i(20, 9))
	a.hunger = 0.0
	a.health = 0.5
	if not _ok(200, func() -> bool: return not e.ses.colony.get_npc(a.id).is_ok(), "A collapses"):
		return
	e.run(25)  # colony alerts refresh every 20 ticks
	assert_true(e.ses.alerts.has_alert(a.id + "/collapsed"), "collapse alert")
	assert_true(e.ses.alerts.has_alert("colony/no_food"), "no-food alert")
	var before := _alert_keys()
	assert_eq(e.reload(), [] as Array[String], "save/load while collapsed")
	e.run(25)
	assert_eq(_alert_keys(), before, "the same alerts are raised again after load")
	assert_false(e.ses.colony.command_move(a.id, Vector2i(30, 9)).ok, "collapsed NPC refuses Move here")
	# Food appears: B feeds A (feed job), save/load while the food is carried.
	e.ses.inventory.spawn_ground(&"meal", 4.0, Vector2i(25, 9))
	var mid_feed := [false]
	if not _ok(1500, func() -> bool:
		var bb: Npc = e.ses.colony.get_npc(b.id)
		var j: Job = e.ses.jobs.get_job(bb.job_id)
		if j != null and j.kind == Job.KIND_FEED and not j.carried_id.is_empty() and not mid_feed[0]:
			mid_feed[0] = true
			var errs: Array[String] = e.reload()
			assert_eq(errs, [] as Array[String], "save/load mid-feed")
		return e.ses.colony.get_npc(a.id).hunger > 50.0, "A fed by B"):
		return
	assert_true(mid_feed[0], "saved while B carried the meal to A")
	if not _ok(2500, func() -> bool: return e.ses.colony.get_npc(a.id).is_ok(), "A gets up"):
		return
	e.run(25)
	assert_false(e.ses.alerts.has_alert(a.id + "/collapsed"), "collapse alert cleared")
	assert_eq(e.ses.colony.deaths(), 0)


func test_death_drops_items_releases_everything_and_alert_stays() -> void:
	var a := s.colony.spawn_npc(Vector2i(10, 9))
	s.stockpiles.designate(Rect2i(40, 9, 2, 1))
	s.inventory.spawn_ground(&"dirt", 120.0, Vector2i(12, 9))
	s.buildings.place(&"bed", Vector2i(30, 9), {&"dirt": 50.0})
	if not _ok(400, func() -> bool: return e.ses.inventory.carried_by(a.id) != null, "A carries dirt"):
		return
	a.hunger = 0.0
	a.health = 0.5
	if not _ok(200, func() -> bool: return not a.is_ok(), "A collapses while hauling"):
		return
	assert_null(e.ses.inventory.carried_by(a.id), "collapse drops the stack")
	assert_eq(a.job_id, "", "job released on collapse")
	if not _ok(6200, func() -> bool: return e.ses.colony.count() == 0, "A dies after 6000 ticks"):
		return
	assert_eq(e.ses.colony.deaths(), 1)
	assert_almost_eq(e.kg(&"dirt"), 120.0, 0.001, "nothing lost")
	for j in e.ses.jobs.all_jobs():
		assert_eq(j.worker_id, "", "no job still held by the dead NPC")
	assert_true(e.ses.alerts.has_alert(a.id + "/died"), "death alert")
	assert_false(e.ses.alerts.has_alert(a.id + "/collapsed"), "collapse alert replaced")
	e.run(50)
	assert_true(e.ses.alerts.has_alert(a.id + "/died"), "death alert stays")


## Alerts are not saved; producers re-raise. A death has no producer left.
## BUG M4A-QA-1: confirmed failing without pending() on 2026-10-22: after
## save/load the "npc:1/died" alert is gone (the deaths counter survives).
func test_death_alert_survives_load() -> void:
	var a := s.colony.spawn_npc(Vector2i(10, 9))
	a.hunger = 0.0
	a.health = 0.5
	_ok(6400, func() -> bool: return e.ses.colony.count() == 0, "A dies")
	assert_true(e.ses.alerts.has_alert(a.id + "/died"))
	assert_eq(e.reload(), [] as Array[String])
	e.run(30)
	assert_eq(e.ses.colony.deaths(), 1)
	assert_true(e.ses.alerts.has_alert(a.id + "/died"), "death alert still listed after load")


# --- Pre-emption of every job phase ------------------------------------------

## A need (critical hunger / exhaustion) interrupts the NPC at a given job
## phase: no orphan reservation, carried stack put down, the job finishes later.
func _preempt(phase_cond: Callable, done_cond: Callable, need: String, msg: String) -> void:
	var n: Npc = e.ses.colony.all_npcs()[0]
	if not _ok(3000, phase_cond, "reach phase: %s" % msg):
		return
	n = e.ses.colony.all_npcs()[0]
	if need == "hunger":
		n.hunger = 5.0
	else:
		n.stamina = 5.0
	e.run(12)  # a walking NPC re-decides at the end of its current step (<= 7 ticks)
	assert_eq(e.errors, [] as Array[String], "invariants after pre-emption (%s)" % msg)
	assert_eq(n.job_id, "", "job released (%s)" % msg)
	var c: ItemStack = e.ses.inventory.carried_by(n.id)
	assert_true(c == null or c.id == n._food_item, "only food in hand (%s)" % msg)
	_ok(9000, done_cond, "job finished after the need (%s)" % msg)


func _setup_food_and_npc() -> void:
	s.colony.spawn_npc(Vector2i(6, 9))
	s.inventory.spawn_ground(&"ration", 20.0, Vector2i(8, 9))


func test_preempt_while_hauling_carrying() -> void:
	_setup_food_and_npc()
	s.stockpiles.designate(Rect2i(40, 9, 2, 1))
	s.inventory.spawn_ground(&"dirt", 80.0, Vector2i(20, 9))
	var n: Npc = s.colony.all_npcs()[0]
	_preempt(func() -> bool:
			var c: ItemStack = e.ses.inventory.carried_by(n.id)
			return c != null and c.material == &"dirt",
		func() -> bool: return e.ses.inventory.ground_kg_at(Vector2i(40, 9)) + e.ses.inventory.ground_kg_at(Vector2i(41, 9)) > 79.0,
		"hunger", "haul carry")


func test_preempt_while_delivering_to_build_site() -> void:
	_setup_food_and_npc()
	s.inventory.spawn_ground(&"rock", 50.0, Vector2i(30, 9))
	s.designations.designate(Rect2i(14, 9, 1, 1), K.BUILD_WALL)
	var n: Npc = s.colony.all_npcs()[0]
	_preempt(func() -> bool:
			var j: Job = e.ses.jobs.get_job(n.job_id)
			return j != null and j.phase == Job.PHASE_DELIVER and e.ses.inventory.carried_by(n.id) != null,
		func() -> bool: return e.ses.grid.get_tile(Vector2i(14, 9)) == TileRegistry.CONCRETE,
		"stamina", "deliver")


func test_preempt_while_building_furniture() -> void:
	_setup_food_and_npc()
	s.inventory.spawn_ground(&"dirt", 50.0, Vector2i(12, 9))
	s.build_orders.order_building(&"bed", Vector2i(20, 9))
	var n: Npc = s.colony.all_npcs()[0]
	_preempt(func() -> bool:
			var j: Job = e.ses.jobs.get_job(n.job_id)
			return j != null and j.kind == Job.KIND_BUILDING and j.phase == Job.PHASE_WORK and j.work_ticks > 2,
		func() -> bool: return e.ses.buildings.count() == 1,
		"hunger", "building work")


func test_preempt_while_cooking() -> void:
	_setup_food_and_npc()
	s.buildings.place(&"kitchen", Vector2i(20, 9), {&"rock": 100.0})
	s.inventory.spawn_ground(&"mushroom", 6.0, Vector2i(15, 9))
	var n: Npc = s.colony.all_npcs()[0]
	_preempt(func() -> bool:
			var j: Job = e.ses.jobs.get_job(n.job_id)
			return j != null and j.kind == Job.KIND_COOK and j.phase == Job.PHASE_WORK and j.work_ticks > 2,
		func() -> bool: return float(e.ses.inventory.spawned_kg_by_material().get(&"meal", 0.0)) > 5.99,
		"stamina", "cooking")
	assert_almost_eq(e.kg(&"mushroom") + float(e.ses.inventory.consumed_kg_by_material().get(&"mushroom", 0.0)), 6.0, 0.001)


## Player commands on an NPC that is carrying its meal (found by the M4a
## random stress: "npc:2 meal item item:161 not reserved for it" right after
## "stop npc:2").
## BUG M4A-QA-3: confirmed failing without pending() on 2026-10-22:
## command_stop -> JobManager.release_npc puts the carried meal down but the
## NPC keeps _food_item (now an unreserved ground stack) and goes on "eating"
## with empty hands (check_invariants: "meal item ... not reserved for it").
func test_stop_while_carrying_meal_leaves_no_dangling_food() -> void:
	var n := s.colony.spawn_npc(Vector2i(6, 9))
	s.inventory.spawn_ground(&"meal", 4.0, Vector2i(10, 9))
	n.hunger = 20.0
	if not _ok(300, func() -> bool:
		var c: ItemStack = e.ses.inventory.carried_by(n.id)
		return c != null and c.material == &"meal", "carrying its meal"):
		return
	assert_true(s.colony.command_stop(n.id).ok)
	assert_eq(e.check(), [] as Array[String], "no dangling food link after Stop")
	_ok(400, func() -> bool: return n.hunger > 60.0, "still gets to eat the meal")


# --- Schedules and GameTime --------------------------------------------------

func test_game_time_boundaries() -> void:
	assert_eq(GameTime.label(0), "Day 1  06:00", "worlds start at 06:00")
	assert_eq(GameTime.hour(3999), 21)
	assert_eq(GameTime.hour(4000), 22)
	assert_eq(GameTime.day(4499), 1)
	assert_eq(GameTime.label(4500), "Day 2  00:00", "rollover at midnight")
	assert_eq(GameTime.label(6000), "Day 2  06:00")
	assert_true(GameTime.is_night(3500))   # 20:00
	assert_false(GameTime.is_night(0))
	assert_eq(GameTime.minute(GameTime.TICKS_PER_HOUR - 1), 59)


## A rested NPC on the DEFAULT schedule (work 06–22) should reach its 22:00
## bedtime. Stamina falls 100 per 16 h awake and "exhausted" is < 15, so it is
## exhausted at ~19:36 every day (exhaustion alert, sleeps early).
## BUG M4A-QA-2: confirmed failing without pending() on 2026-10-22: asleep
## (exhausted, stamina < 15) at 21:58 on day 1 after waking at 06:00 with 100.
func test_default_schedule_reaches_bedtime_without_exhaustion() -> void:
	var n := s.colony.spawn_npc(Vector2i(6, 9))
	s.inventory.spawn_ground(&"ration", 20.0, Vector2i(8, 9))
	s.buildings.place(&"bed", Vector2i(12, 9), {&"dirt": 50.0})
	var exhausted_at := [-1]
	e.run(3990, func() -> bool:
		if exhausted_at[0] < 0 and e.ses.alerts.has_alert(n.id + "/exhausted"):
			exhausted_at[0] = e.t
		return false)
	gut.p("default schedule: exhausted alert at %s, stamina at 21:58 = %.1f" % [
			GameTime.label(exhausted_at[0]) if exhausted_at[0] >= 0 else "never", n.stamina])
	assert_ne(n._activity, &"sleep", "awake before 22:00")
	assert_eq(exhausted_at[0], -1, "no exhaustion alert during a normal work day")


func test_default_schedule_bedtime_and_wake() -> void:
	var n := s.colony.spawn_npc(Vector2i(6, 9))
	s.inventory.spawn_ground(&"ration", 20.0, Vector2i(8, 9))
	s.buildings.place(&"bed", Vector2i(12, 9), {&"dirt": 50.0})
	e.run(3000)
	n.stamina = 60.0   # rested enough to reach 22:00 (see M4A-QA-2)
	e.run(990)
	assert_ne(n._activity, &"sleep", "awake before 22:00")
	_ok(60, func() -> bool: return n._activity == &"sleep", "goes to bed at 22:00")
	_ok(400, func() -> bool: return n._phase == &"asleep" and n._in_bed, "asleep in its bed")
	_ok(DAY, func() -> bool: return n._activity != &"sleep" and GameTime.hour(e.t) >= 6, "wakes after 06:00 rested")


func test_all_work_all_sleep_odd_and_change_mid_sleep() -> void:
	var w := s.colony.spawn_npc(Vector2i(6, 9))
	var z := s.colony.spawn_npc(Vector2i(10, 9))
	var o := s.colony.spawn_npc(Vector2i(14, 9))
	s.inventory.spawn_ground(&"meal", 60.0, Vector2i(8, 9))
	var all_work := PackedByteArray()
	var all_sleep := PackedByteArray()
	var odd := PackedByteArray()
	for h in 24:
		all_work.append(Npc.Activity.WORK)
		all_sleep.append(Npc.Activity.SLEEP)
		odd.append([Npc.Activity.WORK, Npc.Activity.FREE, Npc.Activity.SLEEP][h % 3])
	assert_true(s.colony.set_schedule(w.id, all_work).ok)
	assert_true(s.colony.set_schedule(z.id, all_sleep).ok)
	assert_true(s.colony.set_schedule(o.id, odd).ok)
	var bad := PackedByteArray([7])
	assert_false(s.colony.set_schedule(w.id, bad).ok, "23-hour / junk schedule refused")
	var slept := {w.id: 0, z.id: 0, o.id: 0}
	for i in 2 * DAY:
		e.run(1)
		for n in [w, z, o]:
			if n._activity == &"sleep":
				slept[n.id] += 1
	assert_eq(e.errors, [] as Array[String])
	gut.p("ticks asleep in 2 days: all-work %d, all-sleep %d, odd %d" % [slept[w.id], slept[z.id], slept[o.id]])
	assert_gt(slept[w.id], 0, "all-work NPC still sleeps when exhausted")
	assert_gt(slept[z.id], slept[w.id], "all-sleep NPC sleeps most")
	for n in [w, z, o]:
		assert_true(n.is_ok(), "%s fine after 2 days (%s h%.0f s%.0f)" % [n.id, n.condition, n.hunger, n.stamina])
	# Change mid-sleep: z sleeps; switch to all-work -> keeps sleeping until rested, then works.
	z.stamina = 50.0
	_ok(30, func() -> bool: return z._activity == &"sleep", "z asleep")
	assert_true(s.colony.set_schedule(z.id, all_work).ok)
	_ok(DAY, func() -> bool: return z._activity != &"sleep", "z wakes after the change")
	assert_gt(z.stamina, 99.0, "woke rested")


# --- Alerts -------------------------------------------------------------------

func test_alerts_sorted_by_severity_and_reraised_after_load() -> void:
	var a := s.colony.spawn_npc(Vector2i(10, 9))
	var b := s.colony.spawn_npc(Vector2i(14, 9))
	var c := s.colony.spawn_npc(Vector2i(18, 9))
	a.hunger = 30.0     # hungry (general)
	b.stamina = 10.0    # exhausted (general)
	c.hunger = 0.0      # starving (important)
	c.health = 0.2      # -> collapse (emergency)
	e.run(25)
	var list: Array[Dictionary] = e.ses.alerts.alerts()
	assert_gt(list.size(), 3)
	for i in range(1, list.size()):
		assert_true(list[i - 1]["severity"] >= list[i]["severity"], "sorted by severity: %s" % [list])
	assert_eq(list[0]["severity"], AlertService.Severity.EMERGENCY)
	var before := _alert_keys()
	assert_eq(e.reload(), [] as Array[String])
	e.run(25)
	assert_eq(_alert_keys(), before, "same alerts after load (re-raised)")
