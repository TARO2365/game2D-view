extends GutTest
## QA M3 criterion 7: save v3 round trip in the middle of building (every
## phase) and deconstructing; through the real save files; v2 -> v3
## migration followed by building; orphan crate contents rescued.

const ENV := preload("res://tools/qa_m3_env.gd")
const QA := preload("res://tools/qa_harness.gd")
const FS := preload("res://tests/helpers/fs_util.gd")
const K := DesignationMap.Kind

var reg: TileRegistry
var e: Variant
var dir: String


func before_all() -> void:
	reg = TileRegistry.load_default()


func before_each() -> void:
	e = ENV.new(reg)
	dir = FS.temp_root("qa_m3_save")
	DirAccess.make_dir_recursive_absolute(dir)


func after_each() -> void:
	FS.rm_rf(dir)


func _until(ticks: int, cond: Callable, msg: String) -> bool:
	var ok: bool = e.run(ticks, cond)
	assert_eq(e.errors, [] as Array[String], "invariants (%s)" % msg)
	assert_true(ok, "%s; jobs: %s" % [msg, e.jobs_text()])
	return ok


func _bjob() -> Job:
	for j in e.ses.jobs.all_jobs():
		if j.kind == Job.KIND_BUILDING or j.kind == Job.KIND_DECONSTRUCT:
			return j
	return null


## Bed from crate material: save/load while fetching from the crate, while
## carrying, after a partial delivery and while working.
func test_save_load_in_every_building_phase() -> void:
	var s: WorldSession = e.ses
	var n := s.colony.spawn_npc(Vector2i(40, 9))
	var cid: String = s.buildings.place(&"crate", Vector2i(5, 9), {&"rock": 50.0}).data["id"]
	e.fill_crate(cid, &"dirt", 30.0)   # two trips: 30 from the crate, 20 from the ground
	e.fill_crate(cid, &"rock", 20.0)
	assert_true(s.build_orders.order_building(&"bed", Vector2i(20, 9)).ok)
	var phases := {
		"fetch": func() -> bool: return _bjob() != null and _bjob().phase == Job.PHASE_FETCH and e.ses.colony.get_npc(n.id).is_moving(),
		"carry": func() -> bool: return _bjob() != null and _bjob().phase == Job.PHASE_DELIVER and e.ses.inventory.carried_by(n.id) != null,
		"partial": func() -> bool: return _bjob() != null and e.ses.inventory.site_kg(_bjob().id) > 0.0 and e.ses.inventory.site_kg(_bjob().id) < 50.0,
		"work": func() -> bool: return _bjob() != null and _bjob().phase == Job.PHASE_WORK and _bjob().work_ticks > 3,
	}
	for name: String in phases:
		if not _until(3000, phases[name], "reach phase %s" % name):
			return
		var errs: Array[String] = e.reload()
		assert_eq(errs, [] as Array[String], "save/load in phase %s" % name)
	assert_true(_until(3000, func() -> bool: return e.ses.buildings.count() == 2, "bed finished after 4 loads"))
	assert_almost_eq(e.kg(&"dirt") + e.kg(&"rock"), 0.0 + 0.0, 0.001, "all 50 kg went into the bed")
	assert_almost_eq(e.ses.inventory.crate_kg(cid), 0.0, 0.001)


func test_save_load_mid_deconstruct_of_full_crate() -> void:
	var s: WorldSession = e.ses
	var n := s.colony.spawn_npc(Vector2i(8, 9))
	var cid: String = s.buildings.place(&"crate", Vector2i(12, 9), {&"dirt": 50.0}).data["id"]
	e.fill_crate(cid, &"rock", 1200.0)
	s.designations.designate(Rect2i(12, 9, 1, 1), K.DECONSTRUCT)
	if not _until(1000, func() -> bool: return _bjob() != null and _bjob().work_ticks > 5, "deconstruct working"):
		return
	assert_eq(e.reload(), [] as Array[String], "save/load mid deconstruct")
	assert_true(_until(1000, func() -> bool: return e.ses.buildings.count() == 0, "deconstructed after load"))
	assert_almost_eq(e.kg(&"rock"), 1200.0, 0.001)
	assert_almost_eq(e.kg(&"dirt"), 50.0, 0.001)
	assert_eq(e.ses.colony.get_npc(n.id).job_id, "")


## Real files: SaveService.save + load_world on a generated world with
## buildings, filters, build/deconstruct orders, rooms.
func test_v3_files_round_trip() -> void:
	var h := QA.new(reg, 77, Vector2i(96, 64), 3, 4)
	h.enable_m3()
	for i in 1500:
		if i % 4 == 0:
			h.random_action()
		h.tick()
	var g := h.s.grid
	var x0 := 6   # far from the NPCs' activity near the centre
	var top: int = g.surface_y[x0] + 5
	g.apply_edit(Rect2i(x0, top, 6, 3), WorldGrid.Edit.DIG)   # a closed pocket = room
	var rb := h.s.buildings.place(&"bed", Vector2i(x0 + 1, top + 2), {&"dirt": 50.0})
	var rc := h.s.buildings.place(&"crate", Vector2i(x0 + 4, top + 2), {&"rock": 50.0})
	assert_true(rb.ok and rc.ok, "fixture: %s %s" % [rb, rc])
	if not rc.ok:
		return
	h.s.crates.set_filter(rc.data["id"], [&"iron_ore", &"rock"] as Array[StringName])
	assert_gt(h.s.rooms.room_count(), 0)
	var errs: Array[String] = h.save_load(dir)
	assert_eq(errs, [] as Array[String], "v3 file round trip (comparator incl. buildings, orders, filters, crate kg, rooms)")
	gut.p("v3 files: buildings %d, orders %d, rooms %d" % [h.s.buildings.count(), h.s.build_orders.count(), h.s.rooms.room_count()])


## v2 save (M2 build: no buildings/crates/build_orders) migrates; the colony
## then builds a crate and stores into it.
func test_v2_save_migrates_and_colony_builds() -> void:
	var meta := {"id": "v2", "name": "V2", "seed": 4242, "preset": "custom", "size": Vector2i(96, 64),
			"gen_version": WorldGenerator.GEN_VERSION}
	var s := WorldSession.create_new(meta, reg)
	var g := s.grid
	var cx := g.width / 2
	for x in range(cx - 3, cx + 3):
		s.stockpiles.designate(Rect2i(x, g.surface_y[x] - 1, 1, 1))
	s.inventory.spawn_ground(&"rock", 300.0, Vector2i(cx + 6, g.surface_y[cx + 6] - 1))
	s.inventory.spawn_ground(&"dirt", 90.0, Vector2i(cx - 6, g.surface_y[cx - 6] - 1))  # haul work in flight
	for tick in range(1, 300):
		s.clock.tick_index = tick
		s.simulate_tick(tick)
	var p := SaveService.build_payload(s)
	p["save_version"] = 2
	for k: String in ["buildings", "crates", "build_orders"]:
		p.erase(k)
	assert_true(SaveService.write_atomic(dir.path_join("manual.save"), p).ok)
	var lr := SaveService.load_world(dir, reg, meta)
	assert_true(lr.ok, str(lr))
	assert_eq(lr.data["migrated_from"], 2)
	for k: String in lr.data["dropped"]:
		assert_eq(int(lr.data["dropped"][k]), 0, "dropped %s" % k)
	var l: WorldSession = lr.data["session"]
	assert_eq(l.buildings.count(), 0)
	assert_eq(l.inventory.to_snapshot()["items"], s.inventory.to_snapshot()["items"], "items identical")
	assert_eq(l.jobs.check_invariants(), [] as Array[String])
	# Build a crate on the surface after migration.
	var placed := false
	for dx in range(2, 20):
		var x := cx + dx
		if l.build_orders.order_building(&"crate", Vector2i(x, g.surface_y[x] - 1)).ok:
			placed = true
			break
	assert_true(placed, "a crate order fits on the surface")
	var built := false
	for tick in range(300, 4000):
		l.clock.tick_index = tick
		l.simulate_tick(tick)
		if tick % 10 == 0:
			var errs := l.jobs.check_invariants()
			errs.append_array(QA.extra_invariants(l))
			if not errs.is_empty():
				fail_test("tick %d: %s" % [tick, errs])
				return
		if l.crates.crate_ids().size() == 1:
			built = true
			break
	var info: Array[String] = []
	for j in l.jobs.all_jobs():
		info.append("%s[%s w=%s u=%s]" % [l.jobs.describe_job(j.id), j.phase, j.worker_id, j.unreachable_until])
	for n in l.colony.all_npcs():
		info.append("%s at %s %s job=%s region=%s" % [n.id, n.tile, n.state, n.job_id, n._region_valid])
	var rock := 0.0
	for it in l.inventory.all_items():
		if it.material == &"rock":
			rock += it.kg
	info.append("rock on hand %.0f; orders %s" % [rock, l.build_orders.orders()])
	assert_true(built, "crate built after v2 migration: %s" % "; ".join(PackedStringArray(info.slice(0, 12))))


## A save whose crate building is missing (inconsistent/edited) must not
## strand the crate's stacks: they come back on the ground and are reported.
func test_orphan_crate_items_rescued_and_reported() -> void:
	var h := QA.new(reg, 9, Vector2i(96, 64), 9, 2)
	var g := h.s.grid
	var cx := g.width / 2
	var cid: String = h.s.buildings.place(&"crate", Vector2i(cx + 5, g.surface_y[cx + 5] - 1), {&"rock": 50.0}).data["id"]
	var iid := h.s.inventory.spawn_ground(&"dirt", 120.0, Vector2i(cx, 0))
	h.s.inventory.pick_up(iid, "npc:x", 120.0)
	h.s.inventory.store_in_crate("npc:x", cid)
	var p := SaveService.build_payload(h.s)
	p["buildings"] = {"buildings": []}   # crate entry lost
	var r := SaveService.session_from_payload(bytes_to_var(var_to_bytes(p)), h.s.meta, reg)
	assert_true(r.ok)
	assert_gt(int(r.data["dropped"]["orphan_crate_items"]), 0, "reported as dropped")
	var l: WorldSession = r.data["session"]
	assert_almost_eq(float(l.inventory.total_kg_by_material().get(&"dirt", 0.0)), 120.0, 0.001, "no kg lost")
	for it in l.inventory.all_items():
		assert_eq(it.holder, Inventory.Holder.GROUND)
	assert_eq(l.jobs.check_invariants(), [] as Array[String])
