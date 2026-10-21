extends GutTest
## QA (M2 acceptance 4 + 6): a deep cave whose ONLY connection to the surface
## is a vertical shaft too deep to drop into. Dig orders in the cave must be
## shown unreachable; once the player orders ladders up the shaft, NPCs build
## them from hauled material, climb down, dig, and carry the drops back up to
## the surface stockpile. The run is saved and loaded several times in the
## middle of work (in memory and through the real save files).

const QA := preload("res://tools/qa_harness.gd")
const FS := preload("res://tests/helpers/fs_util.gd")
const K := DesignationMap.Kind
const SIZE := Vector2i(96, 80)
const DEPTH := 24              # shaft rows below the surface tile
const CAVE_ROWS := 3
const MAX_TICKS := 40000
const SAVE_EVERY := 1700
const CHECK_EVERY := 5

var reg: TileRegistry
var dir: String


func before_all() -> void:
	reg = TileRegistry.load_default()


func before_each() -> void:
	dir = FS.temp_root("qa_shaft")
	DirAccess.make_dir_recursive_absolute(dir)


func after_each() -> void:
	FS.rm_rf(dir)


func test_deep_cave_reached_only_through_player_ordered_ladder_shaft() -> void:
	var h := QA.new(reg, 4242, SIZE, 7, 3)
	var g := h.s.grid
	var cx := g.width / 2
	var sx := cx + 8
	var s0: int = g.surface_y[sx]
	# Fixture sanity: the surface next to the shaft is walkable from the NPCs.
	var side := Vector2i(sx - 1, g.surface_y[sx - 1] - 1)
	assert_true(h.s.nav.can_stand(side), "fixture: surface beside the shaft is standable")
	var npc0 := h.s.colony.all_npcs()[0]
	assert_false(h.s.nav.find_path(npc0.tile, [side] as Array[Vector2i]).is_empty() and npc0.tile != side,
			"fixture: NPCs can walk to the shaft")
	# Shaft + cave, carved through the single terrain mutation path.
	assert_true(g.apply_edit(Rect2i(sx, s0, 1, DEPTH), WorldGrid.Edit.DIG).ok)
	var cave_top := s0 + DEPTH - CAVE_ROWS
	g.apply_edit(Rect2i(sx - 4, cave_top, 9, CAVE_ROWS), WorldGrid.Edit.DIG)
	var floor_y := s0 + DEPTH
	var targets: Array[Vector2i] = []
	for x in range(sx - 3, sx + 4):
		targets.append(Vector2i(x, floor_y))
	assert_true(h.s.designations.designate(Rect2i(sx - 3, floor_y, 7, 1), K.DIG).ok)
	# Ladder material on the surface stockpile (harness made 8 zone tiles).
	var zt := h.s.stockpiles.tiles()
	assert_eq(zt.size(), 8)
	for t in zt:
		h.s.inventory.spawn_ground(&"dirt", 100.0, t)
		h.qa_spawned_kg += 100.0

	# Phase 1: no way down -> every cave order is flagged unreachable, none dug.
	var flagged_all := false
	for i in 400:
		h.tick()
		if i % CHECK_EVERY == 0:
			var errs := h.check_all()
			if not errs.is_empty():
				fail_test("phase 1 tick %d: %s" % [h.now(), errs.slice(0, 5)])
				return
		var all := true
		for p in targets:
			all = all and h.s.jobs.is_unreachable(p)
		flagged_all = flagged_all or all
	assert_true(flagged_all, "all deep orders shown unreachable while there is no way down")
	for p in targets:
		assert_eq(h.s.grid.get_tile(p) != TileRegistry.AIR, true, "%s not dug yet" % p)

	# Phase 2: player orders a ladder on every shaft tile.
	var lr := h.s.designations.designate(Rect2i(sx, s0, 1, DEPTH), K.BUILD_LADDER)
	assert_true(lr.ok, str(lr))
	assert_eq(int(lr.data["added"]), DEPTH)
	var next_save := h.now() + SAVE_EVERY
	var done := false
	var max_carried_depth := -1
	var load_errors: Array[String] = []
	var progress_after_load: Array[float] = []
	var p_at_load := -1.0
	for i in MAX_TICKS:
		h.tick()
		for n in h.s.colony.all_npcs():
			if h.s.inventory.carried_by(n.id) != null:
				max_carried_depth = maxi(max_carried_depth, n.tile.y - s0)
		if i % CHECK_EVERY == 0:
			var errs := h.check_all()
			if not errs.is_empty():
				fail_test("phase 2 tick %d: %s\n%s" % [h.now(), errs.slice(0, 5), h.recent_log()])
				return
		if h.now() >= next_save:
			if p_at_load >= 0.0:
				progress_after_load.append(h.progress_kg() - p_at_load)
			load_errors.append_array(h.save_load(dir if h.loads_done % 2 == 1 else ""))
			p_at_load = h.progress_kg()
			next_save = h.now() + SAVE_EVERY
		if i % 50 == 0 and _finished(h, targets, sx, s0):
			done = true
			break
	assert_eq(load_errors, [] as Array[String], "every save/load restored the same state")
	assert_true(done, "cave dug and drops stored within %d ticks (ladders %d/%d, cave dug %d/%d, orders left %d)" % [
			MAX_TICKS, _ladders(h, sx, s0), DEPTH, _dug_count(h, targets), targets.size(),
			h.s.designations.count()])
	assert_gt(h.loads_done, 0, "at least one save/load happened mid-work")
	for v in progress_after_load:
		assert_gt(v, 0.0, "work progressed after every load (%s)" % [progress_after_load])
	assert_gt(max_carried_depth, DEPTH - 4, "items were physically carried up from the cave")
	# Conservation: cave drops (7 x 50 kg) + 800 kg spawned - 24 ladders x 25 kg.
	# Lead (M4a): food (starting rations, eaten over time) is excluded; this checks building materials only.
	var total := 0.0
	var totals := h.s.inventory.total_kg_by_material()
	for m in totals:
		if not h.s.materials.is_food(m):
			total += float(totals[m])
	assert_almost_eq(total, 800.0 + targets.size() * 50.0 - DEPTH * 25.0, 0.01)
	gut.p("shaft: finished at tick %d, loads %d, progress per segment %s, max carry depth %d, stuck %s" % [
			h.now(), h.loads_done, progress_after_load, max_carried_depth, h.stuck_reports])


func _finished(h: Variant, targets: Array[Vector2i], sx: int, s0: int) -> bool:
	if _dug_count(h, targets) < targets.size() or _ladders(h, sx, s0) < DEPTH:
		return false
	for it in h.s.inventory.all_items():
		if not h.s.stockpiles.is_stored(it):
			return false
	return true


func _dug_count(h: Variant, targets: Array[Vector2i]) -> int:
	var c := 0
	for p in targets:
		if h.s.grid.get_tile(p) == TileRegistry.AIR:
			c += 1
	return c


func _ladders(h: Variant, sx: int, s0: int) -> int:
	var c := 0
	for y in range(s0, s0 + DEPTH):
		if h.s.grid.is_ladder(Vector2i(sx, y)):
			c += 1
	return c
