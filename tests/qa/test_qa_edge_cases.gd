extends GutTest
## QA (M2): edge cases written from the acceptance criteria, not from the
## implementation. World edges, ladders at bounds, bedrock, stockpile on a
## ladder, full stockpile, wall over items / NPCs, sealed caves, 100 NPCs on a
## tiny map. Every tick: JobManager.check_invariants, Inventory conservation
## and the QA extra invariants (tools/qa_harness.gd).

const QA := preload("res://tools/qa_harness.gd")
const K := DesignationMap.Kind

var reg: TileRegistry
var g: WorldGrid
var ids: StableIdAllocator
var des: DesignationMap
var inv: Inventory
var sp: StockpileZones
var nav: NavGrid
var jobs: JobManager
var col: Colony
var t := 0


func before_all() -> void:
	reg = TileRegistry.load_default()


## size.x × size.y: rows < air_rows air, then dirt; optional bedrock bottom row.
func _setup(size: Vector2i, air_rows: int = 10, bedrock: bool = true) -> void:
	g = WorldGrid.new(size.x, size.y, reg)
	var tl := PackedByteArray()
	tl.resize(size.x * size.y)
	for y in size.y:
		var id := TileRegistry.AIR
		if bedrock and y == size.y - 1:
			id = TileRegistry.BEDROCK
		elif y >= air_rows:
			id = TileRegistry.DIRT
		for x in size.x:
			tl[y * size.x + x] = id
	g.tiles = tl
	for x in size.x:
		g.surface_y[x] = air_rows
	ids = StableIdAllocator.new()
	des = DesignationMap.new(g)
	inv = Inventory.new(ids)
	sp = StockpileZones.new(g, inv)
	nav = NavGrid.new(g, 3)
	jobs = JobManager.new(g, des, inv, sp, nav, ids)
	col = Colony.new(g, nav, jobs, ids, 99)
	t = 0


func _errors() -> Array[String]:
	var errs := jobs.check_invariants()
	errs.append_array(inv.check_conservation())
	# extra_invariants needs a WorldSession-shaped object: build a light one.
	var ses := WorldSession.new()
	ses.grid = g
	ses.designations = des
	ses.inventory = inv
	ses.stockpiles = sp
	ses.nav = nav
	ses.jobs = jobs
	ses.colony = col
	errs.append_array(QA.extra_invariants(ses))
	return errs


func _run(max_ticks: int, cond: Callable = Callable(), check_every: int = 1) -> bool:
	for i in max_ticks:
		t += 1
		jobs.update(t)
		col.update(t)
		if t % check_every == 0:
			var errs := _errors()
			if not errs.is_empty():
				fail_test("tick %d: %s" % [t, errs.slice(0, 5)])
				return false
		if cond.is_valid() and cond.call():
			return true
	return false


func _dug(p: Vector2i) -> bool:
	return g.get_tile(p) == TileRegistry.AIR


# --- World edges / bounds ------------------------------------------------

func test_npc_walks_to_both_world_edges_and_digs_edge_columns() -> void:
	_setup(Vector2i(40, 30))
	var n := col.spawn_npc(Vector2i(0, 9))
	assert_true(nav.can_stand(Vector2i(0, 9)), "corner x=0 is standable")
	var r := col.command_move(n.id, Vector2i(39, 9))
	assert_true(r.ok, str(r))
	assert_true(_run(400, func() -> bool: return n.tile == Vector2i(39, 9) and not n.is_moving()))
	assert_true(col.command_move(n.id, Vector2i(0, 9)).ok)
	assert_true(_run(400, func() -> bool: return n.tile == Vector2i(0, 9) and not n.is_moving()))
	des.designate(Rect2i(0, 10, 1, 1), K.DIG)
	des.designate(Rect2i(39, 10, 1, 1), K.DIG)
	assert_true(_run(800, func() -> bool: return _dug(Vector2i(0, 10)) and _dug(Vector2i(39, 10))),
			"edge-column digs done")
	assert_eq(jobs.job_count(), 0)
	assert_true(nav.can_stand(n.tile))
	# Move targets outside the world are refused, not clamped into nonsense.
	assert_false(col.command_move(n.id, Vector2i(-1, 9)).ok)
	assert_false(col.command_move(n.id, Vector2i(40, 9)).ok)


func test_ladders_at_top_and_bottom_bounds() -> void:
	_setup(Vector2i(40, 30), 10, false)  # no bedrock: the bottom edge is the floor
	var top_x := 0
	for y in range(0, 10):
		assert_true(g.apply_structure(Vector2i(top_x, y), WorldGrid.Structure.LADDER).ok)
	# Shaft at the right edge down to the last row, with ladders.
	var sx := 39
	g.apply_edit(Rect2i(sx, 10, 1, 20), WorldGrid.Edit.DIG)
	for y in range(10, 30):
		assert_true(g.apply_structure(Vector2i(sx, y), WorldGrid.Structure.LADDER).ok)
	var n := col.spawn_npc(Vector2i(5, 9))
	# Top: highest standable feet row is clearance-1 = 2 (body rows 0..2).
	assert_false(nav.can_stand(Vector2i(top_x, 1)))
	assert_true(nav.can_stand(Vector2i(top_x, 2)))
	assert_true(col.command_move(n.id, Vector2i(top_x, 0)).ok, "nearest standable to the top corner")
	assert_true(_run(600, func() -> bool: return n.tile == Vector2i(top_x, 2) and not n.is_moving()),
			"climbed to the top of the world: %s" % n)
	# Bottom-right corner: feet on the last row (floor is out of bounds = solid).
	assert_true(nav.can_stand(Vector2i(sx, 29)))
	assert_true(col.command_move(n.id, Vector2i(sx, 29)).ok)
	assert_true(_run(1200, func() -> bool: return n.tile == Vector2i(sx, 29) and not n.is_moving()),
			"reached the bottom corner: %s" % n)
	# Dig next to the bottom of the shaft: the item lands on the out-of-bounds floor.
	des.designate(Rect2i(sx - 1, 29, 1, 1), K.DIG)
	assert_true(_run(400, func() -> bool: return _dug(Vector2i(sx - 1, 29))))
	var items := inv.items_at(Vector2i(sx - 1, 29))
	assert_eq(items.size(), 1, "one drop, on the last row")
	assert_true(col.command_move(n.id, Vector2i(5, 9)).ok, "can climb back out")
	assert_true(_run(1200, func() -> bool: return n.tile == Vector2i(5, 9) and not n.is_moving()))


func test_bedrock_cannot_be_ordered_and_tile_above_it_is_dug() -> void:
	_setup(Vector2i(40, 30))
	assert_false(des.designate(Rect2i(0, 29, 40, 1), K.DIG).ok, "bedrock row refuses dig orders")
	sp.designate(Rect2i(2, 9, 4, 1))
	inv.spawn_ground(&"dirt", 400.0, Vector2i(10, 9))
	# Shaft with ladders to just above bedrock.
	g.apply_edit(Rect2i(20, 10, 1, 18), WorldGrid.Edit.DIG)
	for y in range(10, 28):
		g.apply_structure(Vector2i(20, y), WorldGrid.Structure.LADDER)
	col.spawn_npc(Vector2i(8, 9))
	col.spawn_npc(Vector2i(12, 9))
	des.designate(Rect2i(19, 28, 3, 1), K.DIG)  # row right above bedrock
	assert_eq(des.count(), 3)
	assert_true(_run(4000, func() -> bool:
		return _dug(Vector2i(19, 28)) and _dug(Vector2i(20, 28)) and _dug(Vector2i(21, 28)), 5),
			"orders on the bedrock edge get dug")
	assert_eq(g.get_tile(Vector2i(20, 29)), TileRegistry.BEDROCK)
	# The three drops (150 kg dirt) are carried up the ladders into the stockpile.
	assert_true(_run(6000, func() -> bool:
		for it in inv.all_items():
			if it.material == &"dirt" and it.kg < 400.0 and not sp.is_stored(it):
				return false
		return true, 5), "deep drops hauled up: %s" % [inv.to_snapshot()["items"]])


# --- Stockpiles -------------------------------------------------------------

func test_stockpile_on_ladder_tile() -> void:
	_setup(Vector2i(40, 30))
	g.apply_structure(Vector2i(20, 9), WorldGrid.Structure.LADDER)   # on the floor
	assert_true(sp.designate(Rect2i(20, 9, 1, 1)).ok, "ladder tile with a floor can hold a stockpile")
	# A floating ladder tile (no floor) cannot.
	g.apply_edit(Rect2i(30, 10, 1, 5), WorldGrid.Edit.DIG)
	for y in range(10, 15):
		g.apply_structure(Vector2i(30, y), WorldGrid.Structure.LADDER)
	assert_false(sp.designate(Rect2i(30, 12, 1, 1)).ok, "no floor below -> not a stockpile tile")
	col.spawn_npc(Vector2i(5, 9))
	inv.spawn_ground(&"dirt", 60.0, Vector2i(10, 9))
	assert_true(_run(600, func() -> bool: return inv.ground_kg_at(Vector2i(20, 9)) > 59.0))
	assert_eq(jobs.job_count(), 0)


func test_full_stockpile_frees_space_after_build_consumes() -> void:
	_setup(Vector2i(40, 30))
	sp.designate(Rect2i(30, 9, 1, 1))
	inv.spawn_ground(&"rock", StockpileZones.TILE_CAPACITY_KG, Vector2i(30, 9))  # exactly full
	inv.spawn_ground(&"dirt", 40.0, Vector2i(5, 9))
	col.spawn_npc(Vector2i(10, 9))
	_run(200)
	assert_eq(sp.free_capacity(Vector2i(30, 9)), 0.0)
	assert_eq(sp.to_snapshot()["bookings"].size(), 0, "nothing booked on a full tile")
	assert_eq(inv.ground_kg_at(Vector2i(5, 9)), 40.0, "loose dirt stays (no space)")
	des.designate(Rect2i(20, 9, 1, 1), K.BUILD_WALL)  # takes 50 kg rock out of the stockpile
	assert_true(_run(1500, func() -> bool:
		return g.get_tile(Vector2i(20, 9)) == TileRegistry.CONCRETE and inv.ground_kg_at(Vector2i(30, 9)) > 989.0),
			"wall built, then the 40 kg dirt hauled into the freed space")
	assert_almost_eq(inv.ground_kg_at(Vector2i(30, 9)), 990.0, 0.001)
	assert_true(inv.ground_kg_at(Vector2i(30, 9)) <= StockpileZones.TILE_CAPACITY_KG + 0.001, "never overfilled")


func test_stockpile_removed_and_floor_dug_mid_haul() -> void:
	_setup(Vector2i(40, 30))
	sp.designate(Rect2i(30, 9, 3, 1))
	inv.spawn_ground(&"dirt", 150.0, Vector2i(5, 9))
	var n := col.spawn_npc(Vector2i(8, 9))
	assert_true(_run(400, func() -> bool: return inv.carried_by(n.id) != null))
	# Floor under every zone tile vanishes: zones become invalid.
	g.apply_edit(Rect2i(30, 10, 3, 1), WorldGrid.Edit.DIG)
	assert_eq(sp.count(), 0, "zone tiles without floor are removed")
	assert_true(_run(600, func() -> bool: return inv.carried_by(n.id) == null and n.job_id.is_empty()))
	assert_eq(jobs.job_count(), 0, "no haul job without a stockpile")
	assert_almost_eq(float(inv.total_kg_by_material()[&"dirt"]), 150.0, 0.001)


# --- Walls over items / NPCs (deadlock hunting) ----------------------------

## BUG (see docs/qa/M2_QA_REPORT.md QA-1): the builder keeps the wall job and
## waits forever for "items in the way" that only it could haul away.
## Confirmed failing without pending() on 2026-10-20 (wall never built in
## 3000 ticks; NPC idle at (11, 9) holding job:1 "items in the way").
func test_wall_items_in_way_single_npc_no_deadlock() -> void:
	_setup(Vector2i(40, 30))
	sp.designate(Rect2i(30, 9, 2, 1))
	var n := col.spawn_npc(Vector2i(5, 9))
	des.designate(Rect2i(12, 9, 1, 1), K.BUILD_WALL)
	inv.spawn_ground(&"rock", 50.0, Vector2i(2, 9))
	inv.spawn_ground(&"dirt", 30.0, Vector2i(12, 9))  # lies on the wall tile; walls need rock
	var built := _run(3000, func() -> bool: return g.get_tile(Vector2i(12, 9)) == TileRegistry.CONCRETE)
	var j := jobs.job_at(Vector2i(12, 9))
	assert_true(built, "wall should be built (the dirt can be hauled away first); job: %s, npc: %s" % [
			jobs.describe_job(j.id) if j != null else "-", n])


## Checked as a suspected deadlock; it resolves (kept as a regression test).
func test_wall_blocked_by_idle_npc_resolves_without_player() -> void:
	_setup(Vector2i(40, 30))
	var builder := col.spawn_npc(Vector2i(5, 9))
	var idler := col.spawn_npc(Vector2i(12, 9))   # all work enabled, just nothing to do
	inv.spawn_ground(&"rock", 50.0, Vector2i(2, 9))
	des.designate(Rect2i(12, 8, 1, 1), K.BUILD_WALL)
	var built := _run(3000, func() -> bool: return g.get_tile(Vector2i(12, 8)) == TileRegistry.CONCRETE)
	assert_true(built, "wall should get built; builder %s idler %s" % [builder, idler])


## Two adjacent wall orders; each builder ends up standing on the OTHER's wall
## tile and waits for the other to leave.
## BUG QA-3: confirmed failing without pending() on 2026-10-20: after 3000
## ticks npc:1 at (13, 9) holds job:1 "Build wall (12, 9) - blocked by NPC" and
## npc:2 at (12, 9) holds job:2 "Build wall (13, 9) - blocked by NPC".
func test_two_builders_on_each_others_wall_tiles_no_deadlock() -> void:
	_setup(Vector2i(40, 30))
	inv.spawn_ground(&"rock", 50.0, Vector2i(21, 9))
	inv.spawn_ground(&"rock", 50.0, Vector2i(4, 9))
	des.designate(Rect2i(12, 9, 1, 1), K.BUILD_WALL, 9)
	des.designate(Rect2i(13, 9, 1, 1), K.BUILD_WALL, 8)
	var a := col.spawn_npc(Vector2i(20, 9))
	_run(3)
	var b := col.spawn_npc(Vector2i(5, 9))
	var built := _run(3000, func() -> bool:
		return g.get_tile(Vector2i(12, 9)) == TileRegistry.CONCRETE and g.get_tile(Vector2i(13, 9)) == TileRegistry.CONCRETE)
	assert_true(built, "both walls built; a=%s (%s) b=%s (%s)" % [a, jobs.describe_job(a.job_id), b, jobs.describe_job(b.job_id)])


## Stockpile on top of a 3-tile pillar (no ladder): nobody can deliver there.
## The loose item must not be picked up and dropped again forever.
## BUG QA-4: confirmed failing without pending() on 2026-10-20: 20 pick-ups in
## 3000 ticks, the stack is dropped back next to where it lay each time.
func test_unreachable_stockpile_no_pickup_livelock() -> void:
	_setup(Vector2i(40, 30))
	g.apply_edit(Rect2i(30, 6, 1, 4), WorldGrid.Edit.BUILD_WALL)   # pillar rows 6..9
	assert_true(sp.designate(Rect2i(30, 5, 1, 1)).ok)
	inv.spawn_ground(&"dirt", 50.0, Vector2i(10, 9))
	var n := col.spawn_npc(Vector2i(5, 9))
	var pickups := [0]
	inv.items_changed.connect(func(iid: String) -> void:
		var it := inv.get_item(iid)
		if it != null and it.holder == Inventory.Holder.NPC:
			pickups[0] += 1)
	_run(3000)
	assert_not_null(n)
	gut.p("unreachable stockpile: %d pick-ups in 3000 ticks, item at %s" % [pickups[0], inv.all_items()[0].tile])
	assert_true(pickups[0] <= 2, "item picked up %d times for a stockpile nobody can reach" % pickups[0])


func test_wall_never_built_on_npc_or_items() -> void:
	_setup(Vector2i(40, 30))
	sp.designate(Rect2i(34, 9, 4, 1))
	for x in range(2, 6):
		inv.spawn_ground(&"rock", 50.0, Vector2i(x, 9))
	col.spawn_npc(Vector2i(8, 9))
	col.spawn_npc(Vector2i(10, 9))
	des.designate(Rect2i(14, 9, 6, 1), K.BUILD_WALL)
	des.designate(Rect2i(14, 8, 6, 1), K.BUILD_WALL)
	var violations := [0]
	var watch := func() -> bool:
		for n in col.all_npcs():
			for k in 3:
				if g.is_solid_at(n.tile + Vector2i(0, -k)) and not n.is_moving():
					violations[0] += 1
		for it in inv.all_items():
			if it.holder == Inventory.Holder.GROUND and g.is_solid_at(it.tile):
				violations[0] += 1
		return des.count() == 0
	_run(6000, watch)
	assert_eq(violations[0], 0, "no wall ever closed over an NPC body or a ground item")
	gut.p("walls left: %d (material: 200 kg rock for 12 walls of 50 kg -> 4 buildable)" % des.count())
	assert_true(jobs.check_invariants().is_empty())


# --- Unreachable work -----------------------------------------------------

func test_sealed_cave_orders_flagged_unreachable_and_do_not_starve() -> void:
	_setup(Vector2i(64, 64))
	g.apply_edit(Rect2i(20, 40, 10, 5), WorldGrid.Edit.DIG)  # sealed cave
	des.designate(Rect2i(20, 39, 10, 1), K.DIG, 9)           # cave ceiling (touches cave air)
	des.designate(Rect2i(19, 40, 1, 5), K.DIG, 9)            # cave wall
	des.designate(Rect2i(45, 50, 2, 2), K.DIG, 9)            # buried, touches no air at all
	des.designate(Rect2i(5, 10, 1, 1), K.DIG, 1)             # reachable, lowest priority
	for x in [8, 12, 16]:
		col.spawn_npc(Vector2i(x, 9))
	var t0 := Time.get_ticks_usec()
	var max_us := [0]
	var all_flagged := [false]
	var last := [Time.get_ticks_usec()]
	var ok := _run(1500, func() -> bool:
		var now := Time.get_ticks_usec()
		max_us[0] = maxi(max_us[0], now - last[0])
		last[0] = now
		var flagged := true
		for idx: int in des.entries():
			var p := Vector2i(idx % g.width, idx / g.width)
			if p.y >= 39 and not jobs.is_unreachable(p):
				flagged = false
		all_flagged[0] = all_flagged[0] or flagged
		return _dug(Vector2i(5, 10)) and all_flagged[0])
	assert_true(ok, "reachable low-priority order done and every cave order flagged unreachable")
	for n in col.all_npcs():
		var j := jobs.get_job(n.job_id)
		assert_true(j == null or j.tile.y < 39, "%s does not hold a sealed-cave job" % n.id)
	gut.p("sealed cave: %d ticks, %.1f ms total, max tick %.2f ms, searches %d" % [t,
			(Time.get_ticks_usec() - t0) / 1000.0, max_us[0] / 1000.0, nav.searches_total])
	# Opening the cave (terrain change) makes the orders reachable again:
	# a shaft into the cave with ladders down to the cave floor.
	g.apply_edit(Rect2i(24, 10, 1, 30), WorldGrid.Edit.DIG)
	for y in range(10, 45):
		if g.get_tile(Vector2i(24, y)) == TileRegistry.AIR:
			g.apply_structure(Vector2i(24, y), WorldGrid.Structure.LADDER)
	assert_true(_run(6000, func() -> bool: return _dug(Vector2i(19, 42)) and _dug(Vector2i(25, 39)), 5),
			"cave orders done once a ladder shaft connects them")


func test_hundred_npcs_on_a_tiny_map() -> void:
	_setup(Vector2i(40, 30))
	sp.designate(Rect2i(0, 9, 6, 1))
	des.designate(Rect2i(10, 10, 21, 1), K.DIG)
	for i in 100:
		col.spawn_npc(Vector2i(i % 40, 9))
	assert_eq(col.count(), 100)
	var names := {}
	for n in col.all_npcs():
		names[n.full_name] = true
	assert_eq(names.size(), 100, "unique full names")
	var max_workers := [0]
	var ok := _run(3000, func() -> bool:
		var busy := 0
		for n in col.all_npcs():
			if not n.job_id.is_empty():
				busy += 1
		max_workers[0] = maxi(max_workers[0], busy)
		if des.count() > 0:
			return false
		for it in inv.all_items():
			if not sp.is_stored(it):
				return false
		return true)
	assert_true(ok, "all 21 digs done and 1050 kg stored; orders left %d, items %s" % [des.count(), inv.all_items().size()])
	assert_almost_eq(float(inv.total_kg_by_material().get(&"dirt", 0.0)), 21 * 50.0, 0.001)
	assert_true(max_workers[0] <= 21 * 2 + 1, "never more busy NPCs than jobs (%d)" % max_workers[0])
	gut.p("100 NPCs tiny map: %d ticks, peak busy %d, searches %d" % [t, max_workers[0], nav.searches_total])


func test_dig_tile_above_npc_head_and_under_feet_while_carrying() -> void:
	_setup(Vector2i(40, 30))
	# Tunnel exactly 3 tall at rows 12..14 (feet row 14), entered by a ladder.
	g.apply_edit(Rect2i(5, 10, 1, 5), WorldGrid.Edit.DIG)
	for y in range(10, 15):
		g.apply_structure(Vector2i(5, y), WorldGrid.Structure.LADDER)
	g.apply_edit(Rect2i(6, 12, 20, 3), WorldGrid.Edit.DIG)
	sp.designate(Rect2i(30, 9, 2, 1))
	inv.spawn_ground(&"dirt", 120.0, Vector2i(20, 14))
	var n := col.spawn_npc(Vector2i(10, 14))
	assert_true(nav.can_stand(Vector2i(10, 14)))
	# Tile right above its head (row 11) and its floor (row 15) get dug while it hauls.
	assert_true(_run(400, func() -> bool: return inv.carried_by(n.id) != null), "picked up")
	var at := n.tile
	g.apply_edit(Rect2i(at.x, at.y - 3, 1, 1), WorldGrid.Edit.DIG)
	g.apply_edit(Rect2i(at.x, at.y + 1, 1, 1), WorldGrid.Edit.DIG)
	assert_true(_run(3000, func() -> bool:
		return inv.carried_by(n.id) == null and inv.ground_kg_at(Vector2i(30, 9)) + inv.ground_kg_at(Vector2i(31, 9)) > 119.0),
			"haul still completes after falling: %s items %s" % [n, inv.to_snapshot()["items"]])
