extends GutTest
## QA M4a acceptance 2 + 3 + 4, independent layout: 3 farm plots on the
## surface and an UNDERGROUND base (kitchen, table, 3 beds, crate) reached
## only by a laddered shaft. Everything is ordered and built by the NPCs from
## hauled material (nothing dev-placed), 20 kg of rations to start, 3 NPCs,
## 10 in-game days unattended. Save/load (v4 order, full comparator incl.
## needs/schedules/beds/activities/crops) at the first moment an NPC is
## eating, asleep, cooking, feeding or collapsed, and every 7000 ticks.
## Invariants (jobs, kg conservation incl. food, QA M2/M3/M4a) every 10 ticks.

const ENV := preload("res://tools/qa_m3_env.gd")
const K := DesignationMap.Kind
const DAY := GameTime.TICKS_PER_DAY
const SIZE := Vector2i(64, 34)

var reg: TileRegistry


func before_all() -> void:
	reg = TileRegistry.load_default()


func _layout(e: Variant) -> void:
	var s: WorldSession = e.ses
	var g := s.grid
	g.apply_edit(Rect2i(26, 10, 1, 9), WorldGrid.Edit.DIG)          # shaft rows 10..18
	for y in range(10, 19):
		g.apply_structure(Vector2i(26, y), WorldGrid.Structure.LADDER)
	g.apply_edit(Rect2i(27, 16, 18, 3), WorldGrid.Edit.DIG)          # pocket x 27..44, rows 16..18
	s.inventory.spawn_ground(&"rock", 500.0, Vector2i(2, 9))
	s.inventory.spawn_ground(&"rock", 200.0, Vector2i(3, 9))
	s.inventory.spawn_ground(&"dirt", 300.0, Vector2i(4, 9))
	s.inventory.spawn_ground(&"ration", 20.0, Vector2i(6, 9))
	for x in [14, 17, 20]:
		assert_true(s.build_orders.order_building(&"farm_plot", Vector2i(x, 9)).ok, "farm at %d" % x)
	assert_true(s.build_orders.order_building(&"kitchen", Vector2i(28, 18)).ok)
	assert_true(s.build_orders.order_building(&"table", Vector2i(31, 18)).ok)
	for x in [34, 37, 40]:
		assert_true(s.build_orders.order_building(&"bed", Vector2i(x, 18)).ok)
	assert_true(s.build_orders.order_building(&"crate", Vector2i(43, 18)).ok)
	for x in [8, 10, 12]:
		s.colony.spawn_npc(Vector2i(x, 9))


func test_ten_days_underground_base_with_save_load_mid_activity() -> void:
	var e: Variant = ENV.new(reg, SIZE)
	_layout(e)
	var triggers := {"eating": -1, "asleep": -1, "cooking": -1, "feeding": -1, "collapsed": -1}
	var loads := 0
	var next_periodic := 7000
	var daily: Array[String] = []
	var collapses := 0
	var min_hunger := 100.0
	var built_at := -1
	for i in 10 * DAY:
		e.run(1, Callable(), 10)
		if not e.errors.is_empty():
			fail_test("tick %d: %s\n%s" % [e.t, e.errors, e.jobs_text()])
			return
		var s: WorldSession = e.ses
		if built_at < 0 and s.buildings.count() == 9:
			built_at = e.t
		var hit := ""
		for n in s.colony.all_npcs():
			min_hunger = minf(min_hunger, n.hunger)
			if not n.is_ok():
				collapses += 1
				if triggers["collapsed"] < 0:
					hit = "collapsed"
			elif n._activity == &"eat" and n._phase == &"eating" and triggers["eating"] < 0:
				hit = "eating"
			elif n._activity == &"sleep" and n._phase == &"asleep" and triggers["asleep"] < 0:
				hit = "asleep"
			var j := s.jobs.get_job(n.job_id)
			if j != null and j.kind == Job.KIND_COOK and j.phase == Job.PHASE_WORK and triggers["cooking"] < 0:
				hit = "cooking"
			if j != null and j.kind == Job.KIND_FEED and triggers["feeding"] < 0:
				hit = "feeding"
		if hit.is_empty() and e.t >= next_periodic:
			hit = "periodic"
			next_periodic = e.t + 7000
		if not hit.is_empty():
			if triggers.has(hit):
				triggers[hit] = e.t
			var errs: Array[String] = e.reload()
			loads += 1
			if not errs.is_empty():
				fail_test("save/load (%s) at tick %d: %s" % [hit, e.t, errs.slice(0, 5)])
				return
		if e.t % DAY == 0:
			var tot: Dictionary = e.ses.inventory.total_kg_by_material()
			daily.append("D%d ration %.1f mush %.1f meal %.1f" % [GameTime.day(e.t), tot.get(&"ration", 0.0),
					tot.get(&"mushroom", 0.0), tot.get(&"meal", 0.0)])
	var s2: WorldSession = e.ses
	gut.p("all 9 buildings built at tick %d; loads %d; triggers %s" % [built_at, loads, triggers])
	gut.p("food: %s" % ", ".join(PackedStringArray(daily)))
	gut.p("min hunger %.1f, collapse-ticks %d, deaths %d, eaten %s" % [min_hunger, collapses, s2.colony.deaths(),
			s2.inventory.consumed_kg_by_material()])
	assert_gt(built_at, 0, "every building built from hauled material")
	assert_eq(s2.colony.deaths(), 0, "nobody died")
	assert_eq(s2.colony.count(), 3)
	assert_gt(float(s2.inventory.consumed_kg_by_material().get(&"meal", 0.0)), 0.0, "meals cooked and eaten")
	assert_gt(float(s2.inventory.spawned_kg_by_material().get(&"mushroom", 0.0)), 0.0, "mushrooms harvested")
	for k in ["eating", "asleep", "cooking"]:
		assert_gt(int(triggers[k]), 0, "saved/loaded while %s" % k)
	var owned := {}
	for n in s2.colony.all_npcs():
		assert_false(n.bed_id.is_empty(), "%s owns a bed" % n.id)
		owned[n.bed_id] = true
	assert_eq(owned.size(), 3, "three distinct beds")
	assert_eq(e.check(), [] as Array[String])
