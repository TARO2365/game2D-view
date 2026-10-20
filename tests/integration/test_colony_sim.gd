extends GutTest
## 10 simulated minutes of a small hand-made colony (M2 acceptance 1-4):
## a staircase dig, a vertical shaft that NPCs make climbable with ladders
## built from hauled material, a stockpile, 3 NPCs. Every 50 ticks the job
## invariants and kg conservation must hold.
##
## World 80x60: rows < 12 air, 12..58 dirt, 59 bedrock. Surface feet row 11.

const K := DesignationMap.Kind
const SIZE := Vector2i(80, 60)
const GROUND := 12
const TICKS := 6000
const CHECK_EVERY := 50
const SHAFT_X := 28
const SHAFT_BOTTOM := 21     # dug rows GROUND..SHAFT_BOTTOM
const STAIR_X := 46
const STAIR_STEPS := 8

var reg: TileRegistry
var g: WorldGrid
var ids: StableIdAllocator
var des: DesignationMap
var inv: Inventory
var sp: StockpileZones
var nav: NavGrid
var jobs: JobManager
var col: Colony


func before_all() -> void:
	reg = TileRegistry.load_default()


func _make_world() -> WorldGrid:
	var w := WorldGrid.new(SIZE.x, SIZE.y, reg)
	var tiles := PackedByteArray()
	tiles.resize(SIZE.x * SIZE.y)
	for y in SIZE.y:
		var id := TileRegistry.AIR
		if y == SIZE.y - 1:
			id = TileRegistry.BEDROCK
		elif y >= GROUND:
			id = TileRegistry.DIRT
		for x in SIZE.x:
			tiles[y * SIZE.x + x] = id
	w.tiles = tiles
	for x in SIZE.x:
		w.surface_y[x] = GROUND
	return w


## Staircase going down to the right: column STAIR_X + i is dug so that feet
## stand at GROUND + i with clearance and headroom for stepping.
func _stair_tiles() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for i in STAIR_STEPS:
		var x := STAIR_X + i
		for y in range(maxi(GROUND, GROUND + i - 3), GROUND + i + 1):
			out.append(Vector2i(x, y))
	return out


func _designate_shaft_ladders() -> void:
	for y in range(GROUND, SHAFT_BOTTOM + 1):
		var p := Vector2i(SHAFT_X, y)
		if g.get_tile(p) == TileRegistry.AIR and not g.is_ladder(p) and des.get_kind(p) == K.NONE:
			des.designate(Rect2i(p, Vector2i.ONE), K.BUILD_LADDER)


func test_ten_minute_colony_run() -> void:
	g = _make_world()
	ids = StableIdAllocator.new()
	des = DesignationMap.new(g)
	inv = Inventory.new(ids)
	sp = StockpileZones.new(g, inv)
	nav = NavGrid.new(g, 3)
	jobs = JobManager.new(g, des, inv, sp, nav, ids)
	col = Colony.new(g, nav, jobs, ids, 2026)

	assert_true(sp.designate(Rect2i(2, GROUND - 1, 10, 1)).ok)
	var stair := _stair_tiles()
	for p in stair:
		assert_true(des.designate(Rect2i(p, Vector2i.ONE), K.DIG).ok)
	assert_true(des.designate(Rect2i(SHAFT_X, GROUND, 1, SHAFT_BOTTOM - GROUND + 1), K.DIG).ok)
	col.spawn_starting_npcs()
	assert_eq(col.count(), 3)
	var dig_total := stair.size() + (SHAFT_BOTTOM - GROUND + 1)

	var max_jobs := 0
	var carried_ticks := 0
	for tick in range(1, TICKS + 1):
		jobs.update(tick)
		col.update(tick)
		max_jobs = maxi(max_jobs, jobs.job_count())
		for n in col.all_npcs():
			if inv.carried_by(n.id) != null:
				carried_ticks += 1
		if tick % CHECK_EVERY == 0:
			_designate_shaft_ladders()  # the player follows the shaft down with ladders
			var errs := jobs.check_invariants()
			errs.append_array(inv.check_conservation())
			if not errs.is_empty():
				fail_test("tick %d: %s" % [tick, errs])
				return

	# Every order was reachable and is done.
	for p in stair:
		assert_eq(g.get_tile(p), TileRegistry.AIR, "stair tile %s dug" % p)
	for y in range(GROUND, SHAFT_BOTTOM + 1):
		var p := Vector2i(SHAFT_X, y)
		assert_eq(g.get_tile(p), TileRegistry.AIR, "shaft %s dug" % p)
		assert_true(g.is_ladder(p), "ladder at %s" % p)
	assert_eq(des.count(), 0, "no order left")
	assert_eq(jobs.job_count(), 0, "no job left")
	for y in range(GROUND, SHAFT_BOTTOM + 1):
		assert_false(jobs.is_unreachable(Vector2i(SHAFT_X, y)))
	# One 50 kg item per dug tile; ladders consumed 25 kg each.
	var ladders := SHAFT_BOTTOM - GROUND + 1
	var spawned := float(inv.spawned_kg_by_material().get(&"dirt", 0.0))
	assert_almost_eq(spawned, dig_total * 50.0, 0.001)
	assert_almost_eq(float(inv.consumed_kg_by_material().get(&"dirt", 0.0)), ladders * 25.0, 0.001)
	# Dug material sits in the stockpile; nothing in hands, nothing loose.
	var stored := 0.0
	for it in inv.all_items():
		assert_eq(it.holder, Inventory.Holder.GROUND, "%s on the ground" % it.id)
		assert_true(sp.is_stored(it), "%s at %s is in the stockpile" % [it.id, it.tile])
		stored += it.kg
	assert_almost_eq(stored, dig_total * 50.0 - ladders * 25.0, 0.001)
	assert_gt(carried_ticks, 100, "items were physically carried")
	assert_eq(jobs.check_invariants(), [] as Array[String])
	assert_eq(inv.check_conservation(), [] as Array[String])
	for n in col.all_npcs():
		assert_true(nav.can_stand(n.tile), "%s stands on solid ground or a ladder" % n.id)
	gut.p("dug %d tiles, %d ladders, stored %.0f kg, peak jobs %d, searches %d" % [
			dig_total, ladders, stored, max_jobs, nav.searches_total])
