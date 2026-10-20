extends SceneTree
## QA performance probes (M2 acceptance 7, complements tools/bench_npcs.gd).
##  A. Unreachable orders on a Medium world: a sealed cave deep below with 60
##     high-priority dig orders on its walls + one reachable low-priority order.
##     Measures tick time while NPCs keep re-trying the unreachable orders and
##     how long the reachable order waits (starvation).
##  B. Item-heavy colony: 100 NPCs, 2000 loose stacks, 100 ladder orders,
##     a 200-tile stockpile (stresses material search / capacity scans).
## Usage: godot --headless --path . -s res://tools/qa_bench.gd -- [ticks]

const K := DesignationMap.Kind


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var ticks := int(args[0]) if args.size() > 0 else 600
	var reg := TileRegistry.load_default()
	for npcs in [3, 100]:
		_bench_unreachable(reg, npcs, ticks, true)
		_bench_unreachable(reg, npcs, ticks, false)
	_bench_items(reg, ticks)
	quit()


func _make(reg: TileRegistry) -> Dictionary:
	var size: Vector2i = WorldGenerator.PRESETS[&"medium"]
	var g := WorldGenerator.generate(12345, size, reg)
	var ids := StableIdAllocator.new()
	var des := DesignationMap.new(g)
	var inv := Inventory.new(ids)
	var sp := StockpileZones.new(g, inv)
	var nav := NavGrid.new(g, 3)
	var jobs := JobManager.new(g, des, inv, sp, nav, ids)
	var col := Colony.new(g, nav, jobs, ids, 12345)
	return {"g": g, "des": des, "inv": inv, "sp": sp, "nav": nav, "jobs": jobs, "col": col}


func _spawn_npcs(e: Dictionary, n: int, x0: int, x1: int) -> void:
	var g: WorldGrid = e["g"]
	var col: Colony = e["col"]
	var nav: NavGrid = e["nav"]
	var step := maxi(1, (x1 - x0) / n)
	var x := x0
	while col.count() < n:
		var t := Vector2i(x, g.surface_y[x] - 1)
		if nav.can_stand(t):
			col.spawn_npc(t)
		x += step
		if x >= x1:
			x = x0 + 1 + col.count() % step


func _run(e: Dictionary, ticks: int, until: Callable = Callable()) -> Dictionary:
	var jobs: JobManager = e["jobs"]
	var col: Colony = e["col"]
	var nav: NavGrid = e["nav"]
	var total := 0
	var mx := 0
	var s0 := nav.searches_total
	var x0 := nav.expansions_total
	var done_at := -1
	for tick in range(1, ticks + 1):
		var t0 := Time.get_ticks_usec()
		jobs.update(tick)
		col.update(tick)
		var us := Time.get_ticks_usec() - t0
		total += us
		mx = maxi(mx, us)
		if done_at < 0 and until.is_valid() and until.call():
			done_at = tick
	var errs := jobs.check_invariants()
	errs.append_array((e["inv"] as Inventory).check_conservation())
	return {"avg": total / 1000.0 / ticks, "max": mx / 1000.0,
			"searches": nav.searches_total - s0,
			"exp_per_search": float(nav.expansions_total - x0) / maxi(1, nav.searches_total - s0),
			"done_at": done_at, "ok": errs.is_empty()}


func _bench_unreachable(reg: TileRegistry, npcs: int, ticks: int, cave: bool) -> void:
	var e := _make(reg)
	var g: WorldGrid = e["g"]
	var des: DesignationMap = e["des"]
	var cx := g.width / 2
	g.apply_edit(Rect2i(cx - 15, 150, 30, 6), WorldGrid.Edit.DIG)   # sealed cave
	if cave:
		des.designate(Rect2i(cx - 15, 149, 30, 1), K.DIG, 9)  # ceiling
		des.designate(Rect2i(cx - 15, 156, 30, 1), K.DIG, 9)  # floor
	var reach := Vector2i(cx + 40, g.surface_y[cx + 40])
	des.designate(Rect2i(reach, Vector2i.ONE), K.DIG, 1)
	_spawn_npcs(e, npcs, cx - 60, cx + 60)
	var r := _run(e, ticks, func() -> bool: return g.get_tile(reach) == TileRegistry.AIR)
	print("A unreachable  npcs %3d  sealed orders %2d: avg %.3f ms/tick  max %.2f ms  searches %d (%.0f exp each)  reachable low-prio order done at tick %d  invariants %s" % [
			npcs, 60 if cave else 0, r["avg"], r["max"], r["searches"], r["exp_per_search"], r["done_at"], "OK" if r["ok"] else "FAIL"])


func _bench_items(reg: TileRegistry, ticks: int) -> void:
	var e := _make(reg)
	var g: WorldGrid = e["g"]
	var des: DesignationMap = e["des"]
	var inv: Inventory = e["inv"]
	var sp: StockpileZones = e["sp"]
	var cx := g.width / 2
	for x in range(cx - 100, cx + 100):
		sp.designate(Rect2i(x, g.surface_y[x] - 1, 1, 1))
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var placed := 0
	while placed < 2000:
		var x := rng.randi_range(5, g.width - 6)
		var t := Vector2i(x, g.surface_y[x] - 1)
		if (e["nav"] as NavGrid).can_stand(t) and not sp.is_stockpile(t):
			inv.spawn_ground(&"dirt" if rng.randf() < 0.5 else &"rock", rng.randf_range(10.0, 150.0), t)
			placed += 1
	var ladders := 0
	var x := 20
	while ladders < 100 and x < g.width - 20:
		var t := Vector2i(x, g.surface_y[x] - 1)
		if des.designate(Rect2i(t, Vector2i.ONE), K.BUILD_LADDER).ok:
			ladders += 1
		x += 4
	_spawn_npcs(e, 100, 10, g.width - 10)
	var r := _run(e, ticks)
	var stored := 0
	for it in inv.all_items():
		if sp.is_stored(it):
			stored += 1
	print("B items        npcs 100  2000 stacks, %d ladder orders, %d zone tiles: avg %.3f ms/tick  max %.2f ms  searches %d  ladders left %d  stored stacks %d  invariants %s" % [
			ladders, sp.count(), r["avg"], r["max"], r["searches"], des.count(), stored, "OK" if r["ok"] else "FAIL"])
