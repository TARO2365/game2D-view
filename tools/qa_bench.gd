extends SceneTree
## QA performance probes (M2 acceptance 7, complements tools/bench_npcs.gd).
##  A. Unreachable orders on a Medium world: a sealed cave deep below with 60
##     high-priority dig orders on its walls + one reachable low-priority order.
##     Measures tick time while NPCs keep re-trying the unreachable orders and
##     how long the reachable order waits (starvation).
##  B. Item-heavy colony: 100 NPCs, 2000 loose stacks, 100 ladder orders,
##     a 200-tile stockpile (stresses material search / capacity scans).
##  C. M3 base (full WorldSession): 100 NPCs, 30 door-closed rooms with 2 crates
##     and a bed each (60 crates), 2000 loose stacks hauled into the crates,
##     10 furniture orders; plus the cost of room updates for 200 digs inside rooms.
## Usage: godot --headless --path . -s res://tools/qa_bench.gd -- [ticks] [only_c]

const K := DesignationMap.Kind


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var ticks := int(args[0]) if args.size() > 0 else 600
	var only_c := args.size() > 1 and args[1] == "only_c"
	var reg := TileRegistry.load_default()
	if not only_c:
		for npcs in [3, 100]:
			_bench_unreachable(reg, npcs, ticks, true)
			_bench_unreachable(reg, npcs, ticks, false)
		_bench_items(reg, ticks)
	_bench_m3_base(reg, ticks, true)
	_bench_m3_base(reg, ticks, false)
	quit()


func _bench_m3_base(reg: TileRegistry, ticks: int, with_crates: bool = true) -> void:
	var size: Vector2i = WorldGenerator.PRESETS[&"medium"]
	var s := WorldSession.create_new({"id": "bench", "name": "Bench", "seed": 12345, "preset": "medium",
			"size": size, "gen_version": WorldGenerator.GEN_VERSION}, reg)
	var g := s.grid
	var rooms_made := 0
	var x := 30
	while rooms_made < 30 and x < size.x - 30:
		# shaft (x) with ladders, door gap (x+1), pocket x+2..x+7, 3 tall
		var top: int = maxi(g.surface_y[x], g.surface_y[x + 8]) + 5
		g.apply_edit(Rect2i(x, g.surface_y[x], 1, top + 3 - g.surface_y[x]), WorldGrid.Edit.DIG)
		for y in range(g.surface_y[x], top + 3):
			g.apply_structure(Vector2i(x, y), WorldGrid.Structure.LADDER)
		g.apply_edit(Rect2i(x + 1, top, 7, 3), WorldGrid.Edit.DIG)
		var ok := s.buildings.place(&"door", Vector2i(x + 1, top + 2), {&"rock": 50.0}).ok
		if with_crates:
			ok = s.buildings.place(&"crate", Vector2i(x + 3, top + 2), {&"rock": 50.0}).ok and ok
			ok = s.buildings.place(&"crate", Vector2i(x + 4, top + 2), {&"rock": 50.0}).ok and ok
		else:
			s.stockpiles.designate(Rect2i(x + 3, top + 2, 2, 1))  # same 2 tiles as zone
		ok = s.buildings.place(&"bed", Vector2i(x + 6, top + 2), {&"dirt": 50.0}).ok and ok
		if ok:
			rooms_made += 1
		x += 15
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	var placed := 0
	while placed < 2000:
		var px := rng.randi_range(10, size.x - 11)
		var t := Vector2i(px, g.surface_y[px] - 1)
		if s.nav.can_stand(t):
			s.inventory.spawn_ground(&"dirt" if rng.randf() < 0.6 else &"rock", rng.randf_range(10.0, 150.0), t)
			placed += 1
	var furn := 0
	var fx := 20
	while furn < 10 and fx < size.x - 20:
		if s.build_orders.order_building(&"table", Vector2i(fx, g.surface_y[fx] - 1)).ok:
			furn += 1
		fx += 37
	var step := maxi(1, (size.x - 20) / 97)
	var sx := 10
	while s.colony.count() < 100 and sx < size.x - 10:
		var t := Vector2i(sx, g.surface_y[sx] - 1)
		if s.nav.can_stand(t):
			s.colony.spawn_npc(t)
		sx += step
	# Micro costs of the crate queries the job code calls in loops.
	var cids := s.crates.crate_ids()
	if not cids.is_empty():
		var c0 := Time.get_ticks_usec()
		for i in 100:
			s.crates.crate_ids()
		var c1 := Time.get_ticks_usec()
		for i in 100:
			s.crates.free_capacity(cids[i % cids.size()])
		var c2 := Time.get_ticks_usec()
		for i in 100:
			s.crates.find_crate(&"dirt", 50.0, Vector2i(size.x / 2, 30))
		var c3 := Time.get_ticks_usec()
		print("C micro: crate_ids() %.3f ms, free_capacity() %.3f ms, find_crate() %.3f ms (per call, %d items, %d crates)" % [
				(c1 - c0) / 100000.0, (c2 - c1) / 100000.0, (c3 - c2) / 100000.0, s.inventory.all_items().size(), cids.size()])
	else:
		print("C variant: no crates, the same 60 tiles are stockpile zone tiles")
	var total := 0
	var mx := 0
	var jobs_us := 0
	for tick in range(1, ticks + 1):
		s.clock.tick_index = tick
		var t0 := Time.get_ticks_usec()
		s.jobs.update(tick)
		var t1 := Time.get_ticks_usec()
		s.colony.update(tick)
		var us := Time.get_ticks_usec() - t0
		jobs_us += t1 - t0
		total += us
		mx = maxi(mx, us)
	var in_crates := 0.0
	for cid in s.crates.crate_ids():
		in_crates += s.inventory.crate_kg(cid)
	var errs := s.jobs.check_invariants()
	errs.append_array(s.inventory.check_conservation())
	# Room update cost: 200 single-tile digs inside room walls (each re-floods).
	var t1 := Time.get_ticks_usec()
	var digs := 0
	for r in s.rooms.all_rooms():
		var bd: Rect2i = r["bounds"]
		for i in 7:
			if s.grid.apply_edit(Rect2i(bd.end.x + (i % 2), bd.position.y + i % 3, 1, 1), WorldGrid.Edit.DIG).ok:
				digs += 1
	var room_us := Time.get_ticks_usec() - t1
	print("C m3 base     npcs %d  rooms %d (made %d)  crates %d  buildings %d  2000 stacks, %d table orders: avg %.3f ms/tick (jobs.update %.3f)  max %.2f ms  in crates %.0f kg  tables built %d  invariants %s" % [
			s.colony.count(), s.rooms.room_count(), rooms_made, s.crates.crate_ids().size(), s.buildings.count(), furn,
			total / 1000.0 / ticks, jobs_us / 1000.0 / ticks, mx / 1000.0, in_crates, furn - s.build_orders.count(),
			"OK" if errs.is_empty() else str(errs.slice(0, 3))])
	print("C room updates: %d digs next to rooms took %.2f ms total (%.3f ms each)" % [digs, room_us / 1000.0,
			room_us / 1000.0 / maxi(1, digs)])


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
