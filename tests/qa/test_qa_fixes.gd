extends GutTest
## QA final round (M2): independent re-verification of the fixes for QA-1..QA-6
## and of item gravity, plus attempts to break the new behaviour (wall-site
## clearing, step-aside, unreachable-stockpile memory, falling items, save/load
## during a fall and during the "clear" build phase).
## Grid: rows < 10 air, dirt below, bedrock bottom row. Invariants every tick.

const QA := preload("res://tools/qa_harness.gd")
const K := DesignationMap.Kind

var reg: TileRegistry
var ses: WorldSession
var t := 0


func before_all() -> void:
	reg = TileRegistry.load_default()


## WorldSession around a hand-made grid (same composition as the game).
func _setup(size: Vector2i, air_rows: int = 10) -> void:
	var g := WorldGrid.new(size.x, size.y, reg)
	var tl := PackedByteArray()
	tl.resize(size.x * size.y)
	for y in size.y:
		var id := TileRegistry.AIR
		if y == size.y - 1:
			id = TileRegistry.BEDROCK
		elif y >= air_rows:
			id = TileRegistry.DIRT
		for x in size.x:
			tl[y * size.x + x] = id
	g.tiles = tl
	for x in size.x:
		g.surface_y[x] = air_rows
	ses = WorldSession.from_grid({"id": "qa", "seed": 1, "size": size}, g)
	t = 0


## Save/load exactly in SaveService.session_from_payload order, through
## var_to_bytes, onto a copy of the grid (a hand-made grid cannot be
## regenerated from a seed). Returns problems found.
func _reload() -> Array[String]:
	var p := {
		"tiles": ses.grid.tiles.duplicate(), "structures": ses.grid.structures.duplicate(),
		"clock": {"tick_index": t, "speed": 1}, "ids": ses.ids.to_snapshot(),
		"designations": ses.designations.to_snapshot(), "inventory": ses.inventory.to_snapshot(),
		"stockpiles": ses.stockpiles.to_snapshot(), "colony": ses.colony.to_snapshot(),
		"jobs": ses.jobs.to_snapshot(),
	}
	p = bytes_to_var(var_to_bytes(p))
	var before := QA._summary(ses)
	var g := WorldGrid.new(ses.grid.width, ses.grid.height, reg)
	g.tiles = p["tiles"]
	g.structures = p["structures"]
	g.surface_y = ses.grid.surface_y
	var l := WorldSession.from_grid(ses.meta, g)
	l.clock.load_snapshot(p["clock"])
	l.ids.load_snapshot(p["ids"])
	var errs: Array[String] = []
	var dropped := [l.designations.load_snapshot(p["designations"]), l.inventory.load_snapshot(p["inventory"]),
			l.stockpiles.load_snapshot(p["stockpiles"]), l.colony.load_snapshot(p["colony"]),
			l.jobs.load_snapshot(p["jobs"])]
	if dropped != [0, 0, 0, 0, 0]:
		errs.append("dropped %s" % [dropped])
	var after := QA._summary(l)
	before.erase("world_hash")  # same bytes; hash recomputed below
	for k: String in before:
		if typeof(before[k]) != typeof(after[k]) or before[k] != after[k]:
			errs.append("after load %s: %s -> %s" % [k, before[k], after[k]])
	ses = l
	errs.append_array(_errors())
	return errs


func _errors() -> Array[String]:
	var errs := ses.jobs.check_invariants()
	errs.append_array(ses.inventory.check_conservation())
	errs.append_array(QA.extra_invariants(ses))
	return errs


func _run(max_ticks: int, cond: Callable = Callable()) -> bool:
	for i in max_ticks:
		t += 1
		ses.clock.tick_index = t
		ses.simulate_tick(t)
		var errs := _errors()
		if not errs.is_empty():
			fail_test("tick %d: %s" % [t, errs.slice(0, 5)])
			return false
		if cond.is_valid() and cond.call():
			return true
	return false


func _wall(p: Vector2i) -> bool:
	return ses.grid.get_tile(p) == TileRegistry.CONCRETE


func _pickups_counter(acc: Array) -> void:
	ses.inventory.items_changed.connect(func(iid: String) -> void:
		var it := ses.inventory.get_item(iid)
		if it != null and it.holder == Inventory.Holder.NPC:
			acc[0] += 1)


func _floating_ground_items() -> Array[String]:
	var out: Array[String] = []
	for it in ses.inventory.all_items():
		if it.holder == Inventory.Holder.GROUND and not ses.grid.is_solid_at(it.tile + Vector2i.DOWN):
			out.append("%s at %s" % [it.id, it.tile])
	return out


# --- QA-1: items on a wall site -----------------------------------------

func test_qa1_repro_fixed() -> void:
	_setup(Vector2i(40, 30))
	ses.stockpiles.designate(Rect2i(30, 9, 2, 1))
	ses.colony.spawn_npc(Vector2i(5, 9))
	ses.designations.designate(Rect2i(12, 9, 1, 1), K.BUILD_WALL)
	ses.inventory.spawn_ground(&"rock", 50.0, Vector2i(2, 9))
	ses.inventory.spawn_ground(&"dirt", 30.0, Vector2i(12, 9))
	assert_true(_run(3000, func() -> bool: return _wall(Vector2i(12, 9))), "QA-1 repro: wall built")


func test_heavy_stacks_and_three_walls_single_npc_no_stockpile() -> void:
	_setup(Vector2i(40, 30))
	ses.colony.spawn_npc(Vector2i(5, 9))
	ses.inventory.spawn_ground(&"rock", 150.0, Vector2i(2, 9))
	ses.designations.designate(Rect2i(14, 9, 3, 1), K.BUILD_WALL)
	ses.inventory.spawn_ground(&"dirt", 450.0, Vector2i(14, 9))   # > carry capacity: 3 trips
	ses.inventory.spawn_ground(&"iron_ore", 20.0, Vector2i(15, 9))
	ses.inventory.spawn_ground(&"dirt", 5.0, Vector2i(16, 9))
	ses.inventory.spawn_ground(&"dirt", 5.0, Vector2i(16, 9))
	assert_true(_run(8000, func() -> bool:
		return _wall(Vector2i(14, 9)) and _wall(Vector2i(15, 9)) and _wall(Vector2i(16, 9))),
			"all three walls built: orders left %d, %s" % [ses.designations.count(), _jobs_text()])
	for it in ses.inventory.all_items():
		assert_false(ses.grid.is_solid_at(it.tile), "%s not buried at %s" % [it.id, it.tile])
	assert_almost_eq(float(ses.inventory.total_kg_by_material().get(&"dirt", 0.0)), 460.0, 0.001)


## The builder works from ladder tiles (no floor), so it must WALK to a clear
## spot: save/load while it carries the cleared stack.
func test_clear_phase_survives_save_load() -> void:
	_setup(Vector2i(40, 30))
	ses.grid.apply_edit(Rect2i(20, 10, 1, 12), WorldGrid.Edit.DIG)   # shaft rows 10..21, floor 22
	for y in range(10, 22):
		ses.grid.apply_structure(Vector2i(20, y), WorldGrid.Structure.LADDER)
	ses.grid.apply_edit(Rect2i(21, 20, 1, 1), WorldGrid.Edit.DIG)    # alcove, floor (21, 21)
	var site := Vector2i(21, 20)
	var n := ses.colony.spawn_npc(Vector2i(10, 9))
	ses.designations.designate(Rect2i(site, Vector2i.ONE), K.BUILD_WALL)
	ses.inventory.spawn_ground(&"rock", 50.0, Vector2i(2, 9))
	ses.inventory.spawn_ground(&"dirt", 300.0, site)
	var j := ses.jobs.job_at(site)
	assert_true(_run(4000, func() -> bool: return j.phase == Job.PHASE_CLEAR and n.is_moving()),
			"reached the clear phase while walking: %s %s" % [n, _jobs_text()])
	if j.phase != Job.PHASE_CLEAR:
		return
	assert_not_null(ses.inventory.carried_by(n.id))
	var errs := _reload()
	assert_eq(errs, [] as Array[String], "save/load in the clear phase")
	var j2 := ses.jobs.job_at(site)
	assert_eq(j2.phase, Job.PHASE_CLEAR, "clear phase restored")
	assert_true(_run(4000, func() -> bool: return _wall(site)), "wall built after load: %s" % _jobs_text())
	assert_almost_eq(float(ses.inventory.total_kg_by_material().get(&"dirt", 0.0)), 300.0, 0.001)
	for it in ses.inventory.all_items():
		assert_ne(it.tile, site, "nothing buried in the wall")


## Wall row in a 3-tall tunnel: every work position and every clear spot is
## inside the tunnel, partly on other wall orders. Building the outer walls
## first can seal the inner sites off (player-made geometry): acceptable as long
## as they are SHOWN unreachable, nothing is buried and nobody holds them.
func test_wall_row_in_tunnel_with_items() -> void:
	_setup(Vector2i(40, 30))
	ses.grid.apply_edit(Rect2i(5, 10, 1, 5), WorldGrid.Edit.DIG)
	for y in range(10, 15):
		ses.grid.apply_structure(Vector2i(5, y), WorldGrid.Structure.LADDER)
	ses.grid.apply_edit(Rect2i(6, 12, 12, 3), WorldGrid.Edit.DIG)   # tunnel rows 12..14, x 6..17
	ses.colony.spawn_npc(Vector2i(8, 14))
	ses.colony.spawn_npc(Vector2i(16, 14))
	ses.inventory.spawn_ground(&"rock", 200.0, Vector2i(7, 14))
	ses.designations.designate(Rect2i(10, 14, 4, 1), K.BUILD_WALL)  # floor-level walls 10..13
	for x in range(10, 14):
		ses.inventory.spawn_ground(&"dirt", 40.0, Vector2i(x, 14))
	_run(8000, func() -> bool: return ses.designations.count() == 0)
	_assert_leftovers_flagged()
	gut.p("tunnel: walls left %d (%s)" % [ses.designations.count(), _jobs_text()])
	for it in ses.inventory.all_items():
		assert_false(ses.grid.is_solid_at(it.tile), "%s not buried at %s" % [it.id, it.tile])


func _assert_leftovers_flagged() -> void:
	for j in ses.jobs.all_jobs():
		if j.kind == Job.KIND_BUILD:
			assert_true(ses.jobs.is_unreachable(j.tile), "leftover %s shown unreachable" % ses.jobs.describe_job(j.id))
			assert_eq(j.worker_id, "", "nobody holds leftover %s" % j.id)


# --- QA-3: mutual blocking / step aside ----------------------------------

func test_qa3_repro_fixed() -> void:
	_setup(Vector2i(40, 30))
	ses.inventory.spawn_ground(&"rock", 50.0, Vector2i(21, 9))
	ses.inventory.spawn_ground(&"rock", 50.0, Vector2i(4, 9))
	ses.designations.designate(Rect2i(12, 9, 1, 1), K.BUILD_WALL, 9)
	ses.designations.designate(Rect2i(13, 9, 1, 1), K.BUILD_WALL, 8)
	ses.colony.spawn_npc(Vector2i(20, 9))
	_run(3)
	ses.colony.spawn_npc(Vector2i(5, 9))
	assert_true(_run(3000, func() -> bool: return _wall(Vector2i(12, 9)) and _wall(Vector2i(13, 9))))


func test_wall_line_many_builders() -> void:
	_setup(Vector2i(40, 30))
	for x in range(1, 8):
		ses.inventory.spawn_ground(&"rock", 100.0, Vector2i(x, 9))
	ses.designations.designate(Rect2i(14, 7, 6, 3), K.BUILD_WALL)   # 6x3 block, 18 walls
	for x in [10, 12, 14, 16, 18, 20, 22, 24]:
		ses.colony.spawn_npc(Vector2i(x, 9))   # some stand inside the block
	_run(12000, func() -> bool: return ses.designations.count() == 0)
	# The reach rules (|dx| <= 1) cannot reach the inside of a 6-wide block
	# once its bottom row stands: leftovers must be shown unreachable.
	gut.p("6x3 block: walls left %d of 18" % ses.designations.count())
	assert_lt(ses.designations.count(), 18, "some walls got built")
	_assert_leftovers_flagged()
	for n in ses.colony.all_npcs():
		assert_true(ses.nav.can_stand(n.tile), "%s not walled in at %s" % [n.id, n.tile])


## An NPC the player walked onto a wall site: once it has arrived (command
## done) it is asked to step aside; the wall must never close over it.
func test_npc_moved_onto_wall_site_steps_aside_never_walled_in() -> void:
	_setup(Vector2i(40, 30))
	ses.inventory.spawn_ground(&"rock", 50.0, Vector2i(2, 9))
	ses.colony.spawn_npc(Vector2i(5, 9))
	var parked := ses.colony.spawn_npc(Vector2i(20, 9))
	for w in Npc.WORK_KEYS:
		ses.colony.set_work_enabled(parked.id, w, false)
	assert_true(ses.colony.command_move(parked.id, Vector2i(12, 9)).ok)
	ses.designations.designate(Rect2i(12, 8, 1, 1), K.BUILD_WALL)
	var inside := [0]
	_run(1500, func() -> bool:
		for n in ses.colony.all_npcs():
			for k in 3:
				if ses.grid.is_solid_at(n.tile + Vector2i(0, -k)) and not n.is_moving():
					inside[0] += 1
		return _wall(Vector2i(12, 8)))
	assert_true(_wall(Vector2i(12, 8)), "wall built after the NPC stepped aside (at %s)" % parked.tile)
	assert_eq(inside[0], 0, "never walled over an NPC")


# --- QA-4: unreachable stockpile -----------------------------------------

func test_qa4_repro_fixed() -> void:
	_setup(Vector2i(40, 30))
	ses.grid.apply_edit(Rect2i(30, 6, 1, 4), WorldGrid.Edit.BUILD_WALL)
	assert_true(ses.stockpiles.designate(Rect2i(30, 5, 1, 1)).ok)
	ses.inventory.spawn_ground(&"dirt", 50.0, Vector2i(10, 9))
	ses.colony.spawn_npc(Vector2i(5, 9))
	var pickups := [0]
	_pickups_counter(pickups)
	_run(3000)
	gut.p("QA-4 repro: %d pick-ups in 3000 ticks" % pickups[0])
	assert_true(pickups[0] <= 2, "picked up %d times" % pickups[0])


## Nearest zone tile unreachable, a farther one reachable: the stack must
## end up in the reachable one.
## BUG QA-8: confirmed failing without pending() on 2026-10-20: after 4000
## ticks the stack lies at (24, 9) with an open "Haul dirt 50 kg" job that keeps
## booking the unreachable pillar tile; the reachable tile (37, 9) stays empty.
func test_unreachable_nearest_zone_does_not_block_reachable_zone() -> void:
	pending("BUG QA-8: haul keeps booking the nearest (unreachable) zone tile; reachable zone never used")
	return
	@warning_ignore("unreachable_code")
	_setup(Vector2i(40, 30))
	ses.grid.apply_edit(Rect2i(30, 6, 1, 4), WorldGrid.Edit.BUILD_WALL)
	assert_true(ses.stockpiles.designate(Rect2i(30, 5, 1, 1)).ok)   # pillar top: unreachable
	assert_true(ses.stockpiles.designate(Rect2i(37, 9, 1, 1)).ok)   # reachable, farther
	ses.inventory.spawn_ground(&"dirt", 50.0, Vector2i(25, 9))       # d=9 to pillar, d=12 to (37, 9)
	ses.colony.spawn_npc(Vector2i(5, 9))
	var stored := _run(4000, func() -> bool: return ses.inventory.ground_kg_at(Vector2i(37, 9)) > 49.0)
	assert_true(stored, "stack hauled into the reachable zone tile; items %s, jobs %s" % [
			ses.inventory.to_snapshot()["items"], _jobs_text()])


func test_large_unreachable_stockpile_pickups_bounded() -> void:
	_setup(Vector2i(40, 30))
	ses.grid.apply_edit(Rect2i(26, 6, 10, 4), WorldGrid.Edit.BUILD_WALL)   # plateau rows 6..9
	assert_true(ses.stockpiles.designate(Rect2i(26, 5, 10, 1)).ok)       # 10 unreachable tiles
	ses.inventory.spawn_ground(&"dirt", 50.0, Vector2i(10, 9))
	ses.colony.spawn_npc(Vector2i(5, 9))
	var pickups := [0]
	_pickups_counter(pickups)
	_run(6000)
	gut.p("10-tile unreachable stockpile: %d pick-ups in 6000 ticks" % pickups[0])
	assert_true(pickups[0] <= 3, "picked up %d times for a stockpile nobody can reach" % pickups[0])


func test_unreachable_stockpile_memory_after_load() -> void:
	_setup(Vector2i(40, 30))
	ses.grid.apply_edit(Rect2i(30, 6, 1, 4), WorldGrid.Edit.BUILD_WALL)
	ses.stockpiles.designate(Rect2i(30, 5, 1, 1))
	ses.inventory.spawn_ground(&"dirt", 50.0, Vector2i(10, 9))
	ses.colony.spawn_npc(Vector2i(5, 9))
	_run(1000)
	var total := [0]
	for i in 5:
		assert_eq(_reload(), [] as Array[String])
		var pickups := [0]
		_pickups_counter(pickups)
		_run(600)
		total[0] += pickups[0]
	gut.p("unreachable stockpile, 5 save/loads: %d pick-ups after loads" % total[0])
	assert_true(total[0] <= 5, "at most one wasted trip per load (%d)" % total[0])


# --- Item gravity --------------------------------------------------------

func test_reserved_stack_falls_mid_haul_and_is_still_delivered() -> void:
	_setup(Vector2i(40, 30))
	ses.stockpiles.designate(Rect2i(2, 9, 2, 1))
	ses.inventory.spawn_ground(&"dirt", 80.0, Vector2i(30, 9))
	var n := ses.colony.spawn_npc(Vector2i(6, 9))
	assert_true(_run(200, func() -> bool: return not n.job_id.is_empty() and n.is_moving()))
	var iid := ses.jobs.get_job(n.job_id).item_id
	# Pit under the stack: it falls 3 tiles; a ladder lets NPCs reach it.
	ses.grid.apply_edit(Rect2i(29, 10, 3, 3), WorldGrid.Edit.DIG)
	assert_eq(ses.inventory.get_item(iid).tile, Vector2i(30, 12), "stack fell to the pit floor, same id")
	ses.grid.apply_structure(Vector2i(29, 12), WorldGrid.Structure.LADDER)
	ses.grid.apply_structure(Vector2i(29, 11), WorldGrid.Structure.LADDER)
	ses.grid.apply_structure(Vector2i(29, 10), WorldGrid.Structure.LADDER)
	assert_true(_run(3000, func() -> bool:
		return ses.inventory.ground_kg_at(Vector2i(2, 9)) + ses.inventory.ground_kg_at(Vector2i(3, 9)) > 79.0),
			"delivered after the fall: %s" % [ses.inventory.to_snapshot()["items"]])


func test_items_fall_through_ladders_and_into_stockpile() -> void:
	_setup(Vector2i(40, 30))
	ses.grid.apply_edit(Rect2i(20, 10, 1, 10), WorldGrid.Edit.DIG)   # shaft rows 10..19
	for y in range(10, 20):
		ses.grid.apply_structure(Vector2i(20, y), WorldGrid.Structure.LADDER)
	assert_true(ses.stockpiles.designate(Rect2i(20, 19, 1, 1)).ok, "zone at the shaft bottom")
	ses.inventory.spawn_ground(&"rock", 1100.0, Vector2i(21, 9))
	ses.grid.apply_edit(Rect2i(21, 10, 1, 1), WorldGrid.Edit.DIG)    # floor under the stack goes
	var it: ItemStack = ses.inventory.all_items()[0]
	gut.p("stack after floor removed: %s" % it.tile)
	assert_true(ses.grid.is_solid_at(it.tile + Vector2i.DOWN), "rests on a solid tile")
	# A second stack directly above the shaft falls through all ladders.
	ses.inventory.spawn_ground(&"dirt", 30.0, Vector2i(20, 9))
	ses.grid.apply_structure(Vector2i(20, 9), WorldGrid.Structure.LADDER)  # any tiles_changed in the column
	var d: ItemStack = ses.inventory.all_items()[1]
	assert_eq(d.tile, Vector2i(20, 19), "fell through the ladders to the shaft floor")
	assert_true(ses.stockpiles.is_stored(d))
	assert_eq(_errors(), [] as Array[String])


## BUG QA-9: confirmed failing without pending() on 2026-10-20: after "Stop
## job" on a ladder the stack stays at (20, 17) in mid-air (no floor below);
## it only falls if some later terrain change happens in that column.
func test_drop_from_ladder_mid_shaft_does_not_float() -> void:
	pending("BUG QA-9: stacks put down by an NPC on a ladder mid-shaft float (no gravity on drop)")
	return
	@warning_ignore("unreachable_code")
	_setup(Vector2i(40, 30))
	ses.grid.apply_edit(Rect2i(20, 10, 1, 12), WorldGrid.Edit.DIG)
	for y in range(10, 22):
		ses.grid.apply_structure(Vector2i(20, y), WorldGrid.Structure.LADDER)
	ses.grid.apply_edit(Rect2i(21, 19, 6, 3), WorldGrid.Edit.DIG)    # side room at the bottom
	ses.stockpiles.designate(Rect2i(2, 9, 2, 1))
	ses.inventory.spawn_ground(&"dirt", 60.0, Vector2i(24, 21))
	var n := ses.colony.spawn_npc(Vector2i(10, 9))
	assert_true(_run(3000, func() -> bool:
		return ses.inventory.carried_by(n.id) != null and n.tile.x == 20 and n.tile.y < 18 and n.tile.y > 11),
			"climbing the shaft with the stack")
	ses.colony.command_stop(n.id)
	var fl := _floating_ground_items()
	assert_eq(fl, [] as Array[String], "a stack put down on a ladder mid-shaft should fall (gravity)")


func test_save_load_during_npc_fall() -> void:
	_setup(Vector2i(40, 30))
	var n := ses.colony.spawn_npc(Vector2i(20, 9))
	ses.inventory.spawn_ground(&"dirt", 50.0, Vector2i(20, 9))
	ses.inventory.spawn_ground(&"rock", 50.0, Vector2i(21, 9))
	ses.designations.designate(Rect2i(25, 9, 1, 1), K.BUILD_LADDER)
	_run(1)
	ses.grid.apply_edit(Rect2i(19, 10, 3, 4), WorldGrid.Edit.DIG)    # 4-deep pit under NPC + items
	assert_true(_run(10, func() -> bool: return n.is_moving()), "falling")
	assert_eq(_reload(), [] as Array[String], "save/load mid-fall")
	var n2 := ses.colony.get_npc(n.id)
	assert_true(ses.nav.can_stand(n2.tile), "landed on a standable tile after load: %s" % n2)
	assert_eq(_floating_ground_items(), [] as Array[String])
	_run(400)
	assert_eq(_errors(), [] as Array[String])


# --- QA-5 / QA-6 -----------------------------------------------------------

func test_qa5_waiting_state_reported() -> void:
	_setup(Vector2i(40, 30))
	var n := ses.colony.spawn_npc(Vector2i(5, 9))
	ses.colony.set_work_enabled(n.id, &"haul", false)
	var idler := ses.colony.spawn_npc(Vector2i(12, 9))
	ses.colony.command_move(idler.id, Vector2i(12, 9))   # parked by the player: not moved
	ses.inventory.spawn_ground(&"rock", 50.0, Vector2i(2, 9))
	ses.designations.designate(Rect2i(12, 8, 1, 1), K.BUILD_WALL)
	var seen := [false]
	_run(600, func() -> bool:
		if not n.job_id.is_empty() and ses.jobs.get_job(n.job_id).wait_reason == JobManager.REASON_BLOCKED:
			seen[0] = seen[0] or n.state == &"waiting"
			return n.state == &"idle"   # stop if a job holder is shown idle
		return false)
	assert_true(seen[0], "builder blocked by an NPC shows state 'waiting'")


func test_qa6_buried_order_flag_stable() -> void:
	_setup(Vector2i(40, 30))
	ses.colony.spawn_npc(Vector2i(5, 9))
	ses.designations.designate(Rect2i(20, 20, 3, 3), K.DIG)
	var c := [0, 0]  # samples, flagged
	_run(2000, func() -> bool:
		if t > 100:
			c[0] += 1
			if ses.jobs.is_unreachable(Vector2i(21, 21)):
				c[1] += 1
		return false)
	assert_gt(c[0], 0)
	assert_eq(c[1], c[0], "buried order stays flagged (%d/%d)" % [c[1], c[0]])


func _jobs_text() -> String:
	var out: Array[String] = []
	for j in ses.jobs.all_jobs():
		out.append("%s[%s w=%s]" % [ses.jobs.describe_job(j.id), j.phase, j.worker_id])
	return ", ".join(out.slice(0, 8))
