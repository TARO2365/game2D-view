extends GutTest
## QA M3: buildings only from hauled material (kg conserved), placement
## rules, 100 % deconstruct refunds, building loss through support removal.
## Grid 48x32: rows < 10 air, dirt below, bedrock bottom row (feet row 9).

const ENV := preload("res://tools/qa_m3_env.gd")
const K := DesignationMap.Kind

var reg: TileRegistry
var e: Variant  # qa_m3_env instance


func before_all() -> void:
	reg = TileRegistry.load_default()


func before_each() -> void:
	e = ENV.new(reg)


func _ok_run(ticks: int, cond: Callable, msg: String) -> void:
	var ok: bool = e.run(ticks, cond)
	assert_eq(e.errors, [] as Array[String], "invariants")
	assert_true(ok, "%s; jobs: %s" % [msg, e.jobs_text()])


# --- 1. Built only from hauled material; 5. 100 % refund -----------------

func test_buildings_and_wall_refund_exactly_per_material() -> void:
	var s: WorldSession = e.ses
	s.colony.spawn_npc(Vector2i(5, 9))
	s.colony.spawn_npc(Vector2i(7, 9))
	s.inventory.spawn_ground(&"rock", 400.0, Vector2i(2, 9))
	s.inventory.spawn_ground(&"dirt", 400.0, Vector2i(3, 9))
	s.grid.apply_edit(Rect2i(30, 6, 3, 1), WorldGrid.Edit.BUILD_WALL)  # support for the door (dev)
	assert_true(s.build_orders.order_building(&"crate", Vector2i(12, 9)).ok)
	assert_true(s.build_orders.order_building(&"bed", Vector2i(15, 9)).ok)
	assert_true(s.build_orders.order_building(&"table", Vector2i(19, 9)).ok)
	assert_true(s.build_orders.order_building(&"door", Vector2i(31, 9)).ok)
	assert_true(s.designations.designate(Rect2i(26, 9, 1, 1), K.BUILD_WALL).ok)
	_ok_run(6000, func() -> bool: return s.buildings.count() == 4 and s.grid.get_tile(Vector2i(26, 9)) == TileRegistry.CONCRETE,
			"all four buildings and the wall built")
	# Nothing appeared from nowhere: ground + locked in buildings + wall == start.
	var locked: Dictionary = e.building_kg()
	assert_almost_eq(e.kg(&"rock") + float(locked.get(&"rock", 0.0)) + 50.0, 400.0, 0.001, "rock accounted")
	assert_almost_eq(e.kg(&"dirt") + float(locked.get(&"dirt", 0.0)), 400.0, 0.001, "dirt accounted")
	for id in s.buildings.all_ids():
		var mats: Dictionary = s.buildings.get_building(id)["materials"]
		var sum := 0.0
		for m in mats:
			sum += float(mats[m])
		assert_almost_eq(sum, s.buildings.def(s.buildings.get_building(id)["key"]).kg, 0.001, "%s recipe kg" % id)
	# Deconstruct everything the NPCs built (not the dev support row 6).
	assert_true(s.designations.designate(Rect2i(10, 7, 24, 3), K.DECONSTRUCT).ok)
	_ok_run(8000, func() -> bool: return s.buildings.count() == 0 and s.designations.count() == 0,
			"everything deconstructed")
	assert_almost_eq(e.kg(&"rock"), 400.0, 0.001, "100 % rock back")
	assert_almost_eq(e.kg(&"dirt"), 400.0, 0.001, "100 % dirt back")


## A ladder built from rock must refund rock (P-3 / D-021: 100 % of the materials).
## BUG M3-QA-1: confirmed failing without pending() on 2026-10-20: rock 75 / dirt 25
## after deconstruct (JobManager.LADDER_REFUND_MATERIAL = dirt).
func test_ladder_built_from_rock_refunds_rock() -> void:
	var s: WorldSession = e.ses
	s.colony.spawn_npc(Vector2i(5, 9))
	s.inventory.spawn_ground(&"rock", 100.0, Vector2i(2, 9))
	s.designations.designate(Rect2i(12, 9, 1, 1), K.BUILD_LADDER)
	_ok_run(2000, func() -> bool: return s.grid.is_ladder(Vector2i(12, 9)), "ladder built")
	assert_almost_eq(e.kg(&"rock"), 75.0, 0.001)
	s.designations.designate(Rect2i(12, 9, 1, 1), K.DECONSTRUCT)
	_ok_run(2000, func() -> bool: return not s.grid.is_ladder(Vector2i(12, 9)), "ladder removed")
	assert_almost_eq(e.kg(&"rock"), 100.0, 0.001, "rock back")
	assert_almost_eq(e.kg(&"dirt"), 0.0, 0.001, "no dirt created from a rock ladder")


func test_crate_with_contents_deconstructed_refunds_all() -> void:
	var s: WorldSession = e.ses
	s.colony.spawn_npc(Vector2i(5, 9))
	s.inventory.spawn_ground(&"rock", 50.0, Vector2i(2, 9))
	assert_true(s.build_orders.order_building(&"crate", Vector2i(12, 9)).ok)
	_ok_run(2000, func() -> bool: return s.crates.crate_ids().size() == 1, "crate built")
	var cid: String = s.crates.crate_ids()[0]
	e.fill_crate(cid, &"dirt", 700.0)
	e.fill_crate(cid, &"iron_ore", 300.0)
	s.designations.designate(Rect2i(12, 9, 1, 1), K.DECONSTRUCT)
	_ok_run(2000, func() -> bool: return s.buildings.count() == 0, "crate deconstructed")
	assert_almost_eq(e.kg(&"rock"), 50.0, 0.001, "building material back")
	assert_almost_eq(e.kg(&"dirt"), 700.0, 0.001, "contents back")
	assert_almost_eq(e.kg(&"iron_ore"), 300.0, 0.001)
	for it in s.inventory.all_items():
		assert_eq(it.holder, Inventory.Holder.GROUND)
		assert_true(s.grid.is_solid_at(it.tile + Vector2i.DOWN), "%s rests on a floor at %s" % [it.id, it.tile])


func test_order_without_material_never_builds() -> void:
	var s: WorldSession = e.ses
	s.colony.spawn_npc(Vector2i(5, 9))
	s.inventory.spawn_ground(&"dirt", 200.0, Vector2i(2, 9))   # tables and doors need rock
	assert_true(s.build_orders.order_building(&"table", Vector2i(12, 9)).ok)
	assert_false(e.run(1500, func() -> bool: return s.buildings.count() > 0))
	assert_eq(e.errors, [] as Array[String])
	assert_eq(s.buildings.count(), 0, "no table without rock")
	var j: Job = s.jobs.all_jobs()[0]
	assert_true(s.jobs.describe_job(j.id).contains("no material"), s.jobs.describe_job(j.id))
	assert_almost_eq(e.kg(&"dirt"), 200.0, 0.001)


## A tile order placed over a half-supplied building order replaces it; the
## delivered material must come back to the ground.
func test_designation_replaces_building_order_returns_site_material() -> void:
	var s: WorldSession = e.ses
	s.colony.spawn_npc(Vector2i(5, 9))
	s.inventory.spawn_ground(&"rock", 30.0, Vector2i(2, 9))   # bed needs 50: only partial delivery
	s.inventory.spawn_ground(&"dirt", 10.0, Vector2i(3, 9))
	assert_true(s.build_orders.order_building(&"bed", Vector2i(12, 9)).ok)
	_ok_run(2000, func() -> bool:
		var j: Job = s.jobs.all_jobs()[0] if s.jobs.job_count() > 0 else null
		return j != null and s.inventory.site_kg(j.id) >= 40.0 - 0.001, "materials delivered")
	assert_true(s.designations.designate(Rect2i(13, 9, 1, 1), K.BUILD_LADDER).ok)
	assert_eq(s.build_orders.count(), 0, "order replaced")
	assert_eq(e.check(), [] as Array[String])
	_ok_run(2000, func() -> bool: return s.grid.is_ladder(Vector2i(13, 9)), "ladder built from returned material")
	assert_almost_eq(e.kg(&"rock") + e.kg(&"dirt"), 40.0 - 25.0, 0.001)


# --- 2. Placement rules -----------------------------------------------------

func test_placement_rules() -> void:
	var s: WorldSession = e.ses
	var b := s.buildings
	var g := s.grid
	# Floor under every bottom tile.
	g.apply_edit(Rect2i(13, 10, 1, 2), WorldGrid.Edit.DIG)
	assert_eq(b.can_place(&"bed", Vector2i(12, 9)).code, &"no_floor", "bed half over a pit")
	assert_eq(b.can_place(&"table", Vector2i(13, 9)).code, &"no_floor")
	assert_true(b.can_place(&"crate", Vector2i(12, 9)).ok)
	assert_eq(b.can_place(&"crate", Vector2i(13, 9)).code, &"no_floor")
	# Not on ladders, not on solid, not out of the world.
	g.apply_structure(Vector2i(20, 9), WorldGrid.Structure.LADDER)
	assert_eq(b.can_place(&"crate", Vector2i(20, 9)).code, &"blocked")
	assert_eq(b.can_place(&"bed", Vector2i(19, 9)).code, &"blocked")
	assert_eq(b.can_place(&"crate", Vector2i(20, 10)).code, &"blocked", "inside dirt")
	assert_eq(b.can_place(&"bed", Vector2i(47, 9)).code, &"out_of_bounds", "2 wide at the right edge")
	assert_eq(b.can_place(&"door", Vector2i(5, 1)).code, &"out_of_bounds", "door top above row 0")
	# Door: solid tile above its top, floor below; 2-wide gaps allowed (D-023).
	assert_eq(b.can_place(&"door", Vector2i(30, 9)).code, &"no_support")
	g.apply_edit(Rect2i(30, 6, 2, 1), WorldGrid.Edit.BUILD_WALL)
	assert_true(b.can_place(&"door", Vector2i(30, 9)).ok)
	g.apply_structure(Vector2i(31, 8), WorldGrid.Structure.LADDER)
	assert_eq(b.can_place(&"door", Vector2i(31, 9)).code, &"blocked", "ladder inside the gap")
	# Buildings never overlap; a crate cannot stand on a crate.
	assert_true(b.place(&"crate", Vector2i(25, 9), {&"rock": 50.0}).ok)
	assert_eq(b.can_place(&"crate", Vector2i(25, 9)).code, &"blocked")
	assert_eq(b.can_place(&"bed", Vector2i(24, 9)).code, &"blocked")
	assert_eq(b.can_place(&"crate", Vector2i(25, 8)).code, &"no_floor", "a crate is not a floor")
	# Walls / ladders / wall orders refuse building tiles.
	assert_false(g.apply_edit(Rect2i(25, 9, 1, 1), WorldGrid.Edit.BUILD_WALL).ok)
	assert_false(g.apply_structure(Vector2i(25, 9), WorldGrid.Structure.LADDER).ok)
	assert_false(s.designations.designate(Rect2i(25, 9, 1, 1), K.BUILD_WALL).ok)
	assert_false(s.designations.designate(Rect2i(25, 9, 1, 1), K.BUILD_LADDER).ok)
	# Wrong material refused.
	assert_false(b.place(&"table", Vector2i(35, 9), {&"dirt": 50.0}).ok, "tables need rock")


# --- 6. Building loss --------------------------------------------------------

## A crate that is being filled, emptied for a build AND hauled to loses its
## floor: everything drops, no reservation or booking leaks, the work goes on.
func test_crate_lost_mid_haul_and_mid_fetch() -> void:
	var s: WorldSession = e.ses
	var hauler := s.colony.spawn_npc(Vector2i(34, 9))
	var builder := s.colony.spawn_npc(Vector2i(6, 9))
	s.colony.set_work_enabled(builder.id, &"haul", false)
	s.colony.set_work_enabled(hauler.id, &"build", false)
	var r: CommandResult = s.buildings.place(&"crate", Vector2i(12, 9), {&"rock": 50.0})  # dev crate
	var cid: String = r.data["id"]
	e.fill_crate(cid, &"dirt", 500.0)
	s.inventory.spawn_ground(&"dirt", 150.0, Vector2i(40, 9))   # loose: hauled into the crate
	assert_true(s.build_orders.order_building(&"bed", Vector2i(16, 9)).ok)  # material from the crate
	var bed_job: Job = null
	_ok_run(1500, func() -> bool:
		for j in s.jobs.all_jobs():
			if j.kind == Job.KIND_BUILDING:
				bed_job = j
		return s.inventory.carried_by(hauler.id) != null and bed_job != null and not bed_job.worker_id.is_empty(),
			"hauler carrying to the crate and builder fetching")
	var total_before: float = e.kg(&"dirt") + e.kg(&"rock")
	assert_true(s.grid.apply_edit(Rect2i(12, 10, 1, 1), WorldGrid.Edit.DIG).ok)
	assert_eq(s.buildings.count(), 0, "crate lost")
	assert_eq(e.check(), [] as Array[String], "no leak right after the loss")
	assert_almost_eq(e.kg(&"dirt") + e.kg(&"rock"), total_before + 50.0, 0.001, "contents kept + 50 kg refund")
	assert_eq(s.crates.to_snapshot()["bookings"].size(), 0, "crate bookings released")
	_ok_run(4000, func() -> bool: return s.buildings.count() == 1 and s.inventory.carried_by(hauler.id) == null \
			and hauler.job_id.is_empty(), "bed built, hauler finished")
	for it in s.inventory.all_items():
		assert_ne(it.holder, Inventory.Holder.CRATE, "%s not in a vanished crate" % it.id)


func test_door_loses_top_support_by_deconstruct() -> void:
	var s: WorldSession = e.ses
	s.colony.spawn_npc(Vector2i(5, 9))
	s.inventory.spawn_ground(&"rock", 100.0, Vector2i(2, 9))
	s.grid.apply_edit(Rect2i(20, 6, 1, 1), WorldGrid.Edit.BUILD_WALL)  # dev support
	assert_true(s.build_orders.order_building(&"door", Vector2i(20, 9)).ok)
	_ok_run(3000, func() -> bool: return s.buildings.count() == 1, "door built")
	var rock_before: float = e.kg(&"rock")
	assert_true(s.designations.designate(Rect2i(20, 6, 1, 1), K.DECONSTRUCT).ok)
	_ok_run(3000, func() -> bool: return s.grid.get_tile(Vector2i(20, 6)) == TileRegistry.AIR, "support removed")
	assert_eq(s.buildings.count(), 0, "door lost with its support")
	assert_almost_eq(e.kg(&"rock"), rock_before + 50.0 + 50.0, 0.001, "door 50 + wall 50 refunded")


## Same root cause as the loss case: cancelling every deconstruct tile of a
## 2-tile building at once.
## BUG M3-QA-2: confirmed failing without pending() on 2026-10-20: JobManager
## keeps _by_tile[447] -> "job:1" after the job is deleted (_unmap_decon_tile
## erases _job_tiles before _cancel, so _delete_job misses the second tile).
func test_cancel_whole_building_deconstruct_leaves_no_stale_index() -> void:
	var s: WorldSession = e.ses
	s.buildings.place(&"bed", Vector2i(14, 9), {&"dirt": 50.0})
	assert_true(s.designations.designate(Rect2i(14, 9, 2, 1), K.DECONSTRUCT).ok)
	assert_eq(s.jobs.job_count(), 1, "one job for the bed")
	assert_true(s.designations.cancel(Rect2i(14, 9, 2, 1)).ok)
	assert_eq(s.jobs.job_count(), 0)
	assert_eq(e.check(), [] as Array[String], "no tile index entry left for the cancelled job")


## Also fails on M3-QA-2 (stale index of the bed's second tile, confirmed
## failing without pending() on 2026-10-20); the rest is checked with the
## stale-index check relaxed in test_building_lost_while_deconstructed_relaxed.
func test_building_lost_while_being_deconstructed() -> void:
	_lost_while_deconstructed()


## Same scenario with only the known M3-QA-2 symptom tolerated.
func test_building_lost_while_deconstructed_relaxed() -> void:
	ENV.QA.tolerate_stale_tile_index = true
	_lost_while_deconstructed()
	ENV.QA.tolerate_stale_tile_index = false


func _lost_while_deconstructed() -> void:
	var s: WorldSession = e.ses
	var n := s.colony.spawn_npc(Vector2i(5, 9))
	s.buildings.place(&"bed", Vector2i(14, 9), {&"dirt": 50.0})
	s.designations.designate(Rect2i(14, 9, 2, 1), K.DECONSTRUCT)
	_ok_run(1500, func() -> bool: return n.state == &"working", "deconstruct work started")
	s.grid.apply_edit(Rect2i(15, 10, 1, 1), WorldGrid.Edit.DIG)
	assert_eq(s.buildings.count(), 0)
	assert_eq(e.check(), [] as Array[String])
	_ok_run(200, func() -> bool: return n.job_id.is_empty(), "worker released")
	assert_eq(s.designations.count(), 0, "deconstruct orders on the vanished bed are gone")
	assert_almost_eq(e.kg(&"dirt"), 50.0, 0.001, "refunded exactly once")
