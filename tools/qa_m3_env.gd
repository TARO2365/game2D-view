extends RefCounted
## QA M3 test environment (not a test script: no test_ prefix).
## A WorldSession around a hand-made grid (rows < air_rows air, dirt below,
## bedrock bottom row), a tick driver that checks every invariant, and a
## save/load that follows SaveService.session_from_payload's v3 order exactly
## (buildings, designations, inventory, stockpiles, crates, orphan rescue,
## build orders, colony, jobs; rooms rebuilt last) through var_to_bytes.

const QA := preload("res://tools/qa_harness.gd")

var reg: TileRegistry
var ses: WorldSession
var t := 0
var errors: Array[String] = []


func _init(registry: TileRegistry, size: Vector2i = Vector2i(48, 32), air_rows: int = 10) -> void:
	reg = registry
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
	ses = WorldSession.from_grid({"id": "qa_m3", "seed": 1, "size": size}, g)


func check() -> Array[String]:
	var errs := ses.jobs.check_invariants()
	errs.append_array(ses.inventory.check_conservation())
	errs.append_array(QA.extra_invariants(ses))
	return errs


## Runs up to max_ticks; stops early when cond returns true (returns true).
## Invariant violations are collected in `errors` and stop the run.
func run(max_ticks: int, cond: Callable = Callable(), check_every: int = 1) -> bool:
	for i in max_ticks:
		t += 1
		ses.clock.tick_index = t
		ses.simulate_tick(t)
		if t % check_every == 0:
			var e := check()
			if not e.is_empty():
				errors.append("tick %d: %s" % [t, e.slice(0, 4)])
				return false
		if cond.is_valid() and cond.call():
			return true
	return false


## Save/load (v3 order). Returns problems (dropped entries, summary
## differences incl. buildings, orders, crate filters/kg, rooms, carried
## items, job workers; invariants after load).
func reload() -> Array[String]:
	var p := {
		"tiles": ses.grid.tiles.duplicate(), "structures": ses.grid.structures.duplicate(),
		"clock": {"tick_index": t, "speed": 1}, "ids": ses.ids.to_snapshot(),
		"buildings": ses.buildings.to_snapshot(), "designations": ses.designations.to_snapshot(),
		"inventory": ses.inventory.to_snapshot(), "stockpiles": ses.stockpiles.to_snapshot(),
		"crates": ses.crates.to_snapshot(), "build_orders": ses.build_orders.to_snapshot(),
		"farming": ses.farming.to_snapshot(), "kitchens": ses.kitchens.to_snapshot(),
		"colony": ses.colony.to_snapshot(), "jobs": ses.jobs.to_snapshot(),
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
	var dropped := {}
	dropped["buildings"] = l.buildings.load_snapshot(p["buildings"])
	dropped["designations"] = l.designations.load_snapshot(p["designations"])
	dropped["inventory"] = l.inventory.load_snapshot(p["inventory"])
	dropped["stockpiles"] = l.stockpiles.load_snapshot(p["stockpiles"])
	dropped["crates"] = l.crates.load_snapshot(p["crates"])
	dropped["orphan_crate_items"] = SaveService._rescue_orphan_crate_items(l)
	dropped["build_orders"] = l.build_orders.load_snapshot(p["build_orders"])
	dropped["farming"] = l.farming.load_snapshot(p["farming"])
	dropped["kitchens"] = l.kitchens.load_snapshot(p["kitchens"])
	dropped["colony"] = l.colony.load_snapshot(p["colony"])
	dropped["jobs"] = l.jobs.load_snapshot(p["jobs"])
	l.rooms.rebuild_all()
	var errs: Array[String] = []
	for k: String in dropped:
		if int(dropped[k]) != 0:
			errs.append("load dropped %d %s" % [dropped[k], k])
	var after := QA._summary(l)
	for k: String in before:
		if typeof(before[k]) != typeof(after[k]) or before[k] != after[k]:
			errs.append("after load %s: %s -> %s" % [k, before[k], after[k]])
	ses = l
	errs.append_array(check())
	return errs


func kg(mat: StringName) -> float:
	return float(ses.inventory.total_kg_by_material().get(mat, 0.0))


## Material locked in buildings, per material (StringName -> kg).
func building_kg() -> Dictionary:
	var out := {}
	for id in ses.buildings.all_ids():
		var m: Dictionary = ses.buildings.get_building(id)["materials"]
		for k in m:
			out[StringName(k)] = float(out.get(StringName(k), 0.0)) + float(m[k])
	return out


## Puts kg of material straight into a crate (setup only).
func fill_crate(cid: String, mat: StringName, kg_: float) -> void:
	var iid := ses.inventory.spawn_ground(mat, kg_, Vector2i(0, 0))
	ses.inventory.pick_up(iid, "npc:setup", kg_)
	ses.inventory.store_in_crate("npc:setup", cid)


func jobs_text() -> String:
	var out: Array[String] = []
	for j in ses.jobs.all_jobs():
		out.append("%s[%s w=%s u=%s]" % [ses.jobs.describe_job(j.id), j.phase, j.worker_id, j.unreachable_until])
	return ", ".join(out.slice(0, 10))
