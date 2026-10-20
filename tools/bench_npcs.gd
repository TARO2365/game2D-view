extends SceneTree
## Benchmark: 100 NPCs on a Medium world with many dig orders (M2 plan item 11).
## Measures simulation tick time (JobManager.update + Colony.update) and path
## searches per tick. Rendering/FPS is not measured here.
## Orders: a V-shaped valley (walkable in, out and across) every STAIR_EVERY
## columns plus one 4x6 pit (NPCs that dig down into it get confined).
## Usage: godot --headless --path . -s res://tools/bench_npcs.gd

const SEED := 12345
const NPCS := 100
const TICKS := 600
const STAIR_EVERY := 12
const STAIR_STEPS := 10
const PIT_X := 130


func _init() -> void:
	var reg := TileRegistry.load_default()
	var size: Vector2i = WorldGenerator.PRESETS[&"medium"]
	var g := WorldGenerator.generate(SEED, size, reg)
	var ids := StableIdAllocator.new()
	var des := DesignationMap.new(g)
	var inv := Inventory.new(ids)
	var sp := StockpileZones.new(g, inv)
	var nav := NavGrid.new(g, 3)
	var jobs := JobManager.new(g, des, inv, sp, nav, ids)
	var col := Colony.new(g, nav, jobs, ids, SEED)

	# Stockpile: 24 surface tiles around the centre.
	var cx := size.x / 2
	for x in range(cx - 12, cx + 12):
		sp.designate(Rect2i(x, g.surface_y[x] - 1, 1, 1))
	# V-shaped valleys (down STAIR_STEPS/2 steps, then up again) so surface
	# traffic can still cross them.
	# Depth follows the local surface; valleys with a step > 1 tile are skipped.
	for x0 in range(8, size.x - STAIR_STEPS - 8, STAIR_EVERY):
		var feet: Array[int] = [g.surface_y[x0 - 1] - 1]
		for i in STAIR_STEPS:
			feet.append(g.surface_y[x0 + i] - 1 + mini(i + 1, STAIR_STEPS - i))
		feet.append(g.surface_y[x0 + STAIR_STEPS] - 1)
		var ok := true
		for i in range(1, feet.size()):
			ok = ok and absi(feet[i] - feet[i - 1]) <= 1
		if not ok:
			continue
		for i in STAIR_STEPS:
			des.designate(Rect2i(x0 + i, feet[i + 1] - 3, 1, 4), DesignationMap.Kind.DIG)
	# One 4x6 pit: NPCs that dig down into it get confined (no ladders).
	des.designate(Rect2i(PIT_X, g.surface_y[PIT_X], 4, 6), DesignationMap.Kind.DIG)
	# NPCs spread over the surface.
	var step := maxi(1, (size.x - 20) / NPCS)
	var x := 10
	while col.count() < NPCS and x < size.x - 10:
		var t := Vector2i(x, g.surface_y[x] - 1)
		if nav.can_stand(t):
			col.spawn_npc(t)
		x += step
	var orders0 := des.count()
	print("medium %dx%d  npcs %d  dig orders %d  stockpile tiles %d" % [size.x, size.y,
			col.count(), orders0, sp.count()])

	var total_us := 0
	var jobs_us := 0
	var max_us := 0
	var max_tick := 0
	var searches0 := nav.searches_total
	var max_searches := 0
	for tick in range(1, TICKS + 1):
		var before := nav.searches_total
		var t0 := Time.get_ticks_usec()
		jobs.update(tick)
		var t1 := Time.get_ticks_usec()
		col.update(tick)
		var us := Time.get_ticks_usec() - t0
		jobs_us += t1 - t0
		total_us += us
		if us > max_us:
			max_us = us
			max_tick = tick
		max_searches = maxi(max_searches, nav.searches_total - before)
	var searches := nav.searches_total - searches0
	var busy := 0
	var confined := 0
	for n in col.all_npcs():
		if not n.job_id.is_empty():
			busy += 1
		if n._region_valid:
			confined += 1
	var stored := 0
	for it in inv.all_items():
		if sp.is_stored(it):
			stored += 1
	var unreachable := 0
	for j in jobs.all_jobs():
		if jobs.is_unreachable(j.tile):
			unreachable += 1
	var errs := jobs.check_invariants()
	errs.append_array(inv.check_conservation())
	print("ticks %d  avg %.3f ms/tick (jobs.update %.3f)  max %.3f ms (tick %d)" % [TICKS,
			total_us / 1000.0 / TICKS, jobs_us / 1000.0 / TICKS, max_us / 1000.0, max_tick])
	print("path searches %d  avg %.2f/tick  max %d/tick (budget %d)  avg %.0f expansions, %.3f ms each; search share %.3f ms/tick" % [
			searches, float(searches) / TICKS, max_searches, NavGrid.PATH_BUDGET_PER_TICK,
			float(nav.expansions_total) / maxi(1, nav.searches_total),
			nav.search_usec_total / 1000.0 / maxi(1, nav.searches_total),
			nav.search_usec_total / 1000.0 / TICKS])
	print("dug %d/%d  items %d (stored %d)  jobs %d (unreachable %d)  npcs busy %d confined %d  invariants %s" % [
			orders0 - des.count(), orders0, inv.all_items().size(), stored, jobs.job_count(),
			unreachable, busy, confined, "OK" if errs.is_empty() else str(errs.slice(0, 3))])
	quit()
