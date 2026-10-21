extends RefCounted
## QA harness (M2, QA Agent). Not a game system: used by tests/qa/*.gd and
## tools/qa_stress.gd to drive a WorldSession with seeded random player actions
## and check invariants after every tick.
##
## Checks per tick (check_all):
##   - JobManager.check_invariants()       (contract §7)
##   - Inventory.check_conservation()      (contract §3)
##   - extra_invariants(): QA's own, independent of the implementation's
##     checker (open-job buckets / priority counters, order <-> job mapping,
##     carry capacity, booking totals, NPC bounds, site over-delivery).
##
## Random actions are logged (last LOG_KEEP) so a failure can be reproduced
## with the same world seed + rng seed.

const K := DesignationMap.Kind
const LOG_KEEP := 40
const STUCK_TICKS := 3000        # a job held without any progress this long = stuck
const UNSTANDABLE_GRACE := 3     # ticks an idle NPC may be on a non-standable tile
const EPS := 0.001
## Known bug M3-QA-2 (stale JobManager._by_tile entries after a multi-tile
## deconstruct job is cancelled): tests/stress may relax only this check.
static var tolerate_stale_tile_index := false

var reg: TileRegistry
var s: WorldSession
var rng := RandomNumberGenerator.new()
var world_seed: int
var size: Vector2i
var log_lines: Array[String] = []
var action_weights := {}
## Actions enabled by name (tests can switch groups off).
var allow_terrain := true
var allow_walls_over := true     # dev-style apply_edit BUILD_WALL (can bury items / NPCs)
var max_npcs := 24

## Stats
var ticks_run := 0
var actions_run := 0
var loads_done := 0
var qa_spawned_kg := 0.0         # kg spawned by QA actions (not by digging)
var max_tick_usec := 0
var total_tick_usec := 0
var stuck_reports: Array[String] = []
var _npc_watch := {}             # npc id -> {"key": String, "since": int}
var _unstandable := {}           # npc id -> consecutive ticks


func _init(registry: TileRegistry, wseed: int, wsize: Vector2i, rng_seed: int, npcs: int = 6) -> void:
	reg = registry
	world_seed = wseed
	size = wsize
	rng.seed = rng_seed
	s = WorldSession.create_new({"id": "qa", "name": "QA", "seed": wseed, "preset": "custom",
			"size": wsize, "gen_version": WorldGenerator.GEN_VERSION}, reg)
	while s.colony.count() < npcs:
		var t := _random_surface_feet(s.grid.width / 2, 20)
		if t != Vector2i(-1, -1):
			s.colony.spawn_npc(t)
	# Starting stockpile on the surface near the centre.
	var cx := s.grid.width / 2
	for x in range(cx - 4, cx + 4):
		s.stockpiles.designate(Rect2i(x, s.grid.surface_y[x] - 1, 1, 1))
	action_weights = {
		"dig": 10, "ladder": 5, "wall": 4, "cancel": 4, "priority": 4,
		"stock_add": 3, "stock_remove": 2, "move": 4, "stop": 3, "toggle": 3,
		"dig_under_npc": 2, "dig_under_stock": 2, "wall_over": 1, "remove_ladder": 1,
		"spawn_item": 3, "spawn_npc": 1,
	}


## Adds the M3 player actions (building orders, deconstruct, crate filters,
## cancel/priority of building orders, floor dug out under buildings).
func enable_m3() -> void:
	action_weights["building"] = 8
	action_weights["deconstruct"] = 4
	action_weights["build_cancel"] = 1
	action_weights["build_priority"] = 2
	action_weights["crate_filter"] = 2
	action_weights["dig_under_building"] = 1
	action_weights["carve_room"] = 2
	action_weights["spawn_item"] = 5  # buildings need material


# --- Simulation ---------------------------------------------------------

func tick() -> void:
	s.clock.tick_index += 1
	var t0 := Time.get_ticks_usec()
	s.simulate_tick(s.clock.tick_index)
	var us := Time.get_ticks_usec() - t0
	total_tick_usec += us
	max_tick_usec = maxi(max_tick_usec, us)
	ticks_run += 1
	_watch_npcs()


func now() -> int:
	return s.clock.tick_index


## kg dug out of the ground (spawned by dig jobs) + kg consumed by builds.
func progress_kg() -> float:
	var spawned := 0.0
	for m in s.inventory.spawned_kg_by_material().values():
		spawned += float(m)
	var consumed := 0.0
	for m in s.inventory.consumed_kg_by_material().values():
		consumed += float(m)
	return (spawned - qa_spawned_kg) + consumed


# --- Invariants ---------------------------------------------------------

func check_all() -> Array[String]:
	var errs := s.jobs.check_invariants()
	errs.append_array(s.inventory.check_conservation())
	errs.append_array(extra_invariants(s))
	for id: String in _unstandable:
		if int(_unstandable[id]) > UNSTANDABLE_GRACE:
			errs.append("QA: %s idle on a non-standable tile for %d ticks" % [id, _unstandable[id]])
	return errs


## QA's own invariants (white-box: reads JobManager internals on purpose).
static func extra_invariants(ses: WorldSession) -> Array[String]:
	var errs: Array[String] = []
	var jm := ses.jobs
	var counts := PackedInt32Array()
	counts.resize(DesignationMap.MAX_PRIORITY + 1)
	for job: Job in jm.all_jobs():
		if job._open:
			counts[job._open_prio] += 1
			if job._open_prio != job.priority:
				errs.append("QA: open %s listed under priority %d, has %d" % [job.id, job._open_prio, job.priority])
			var b: Variant = jm._open_chunks.get(jm._chunk_of(job.tile))
			if b == null or not (b as Dictionary).has(job.id):
				errs.append("QA: open %s missing from its chunk bucket" % job.id)
		match job.kind:
			Job.KIND_HAUL, Job.KIND_FARM, Job.KIND_COOK, Job.KIND_FEED:
				pass  # Lead (M4a): these jobs have no player designation/priority to compare
			Job.KIND_BUILDING:
				# Building orders live in BuildOrders, not in the tile designations (M3).
				var o := ses.build_orders.get_order(job.order_id) if ses.build_orders != null else {}
				if o.is_empty():
					errs.append("QA: building job %s has no order %s" % [job.id, job.order_id])
				elif int(o["priority"]) != job.priority:
					errs.append("QA: %s priority %d != building order priority %d" % [job.id, job.priority, o["priority"]])
			_:
				# dig / build / deconstruct: the designation on the job's own tile
				# (a building deconstruct job keeps its main tile's priority).
				if job.priority != ses.designations.get_priority(job.tile):
					errs.append("QA: %s priority %d != order priority %d" % [job.id, job.priority,
							ses.designations.get_priority(job.tile)])
		if job.needs_material() and job.kind == Job.KIND_BUILDING and ses.buildings != null:
			var bd := ses.buildings.def(job.building_key)
			if bd != null and ses.inventory.site_kg(job.id) > bd.kg + EPS:
				errs.append("QA: %s over-delivered %.3f > %.3f" % [job.id, ses.inventory.site_kg(job.id), bd.kg])
		if job.kind == Job.KIND_BUILD:
			var need := float(ConstructionDefs.recipe(job.order_kind)["kg"])
			if ses.inventory.site_kg(job.id) > need + EPS:
				errs.append("QA: %s over-delivered %.3f > %.3f" % [job.id, ses.inventory.site_kg(job.id), need])
	for p in counts.size():
		if counts[p] != jm._prio_count[p]:
			errs.append("QA: _prio_count[%d] = %d, open jobs at that priority = %d" % [p, jm._prio_count[p], counts[p]])
	for ci: int in jm._open_chunks:
		for jid: String in (jm._open_chunks[ci] as Dictionary):
			var j: Job = jm.get_job(jid)
			if j == null or not j._open:
				errs.append("QA: bucket %d lists %s which is not open/alive" % [ci, jid])
	var entries := ses.designations.entries()
	for idx: int in entries:
		var jid: String = jm._by_tile.get(idx, "")
		var j: Job = jm.get_job(jid)
		if j == null:
			errs.append("QA: order at %s (kind %d) has no job" % [jm._tile_of(idx), entries[idx]])
		elif j.order_kind != entries[idx]:
			errs.append("QA: order at %s kind %d but job %s kind %d" % [jm._tile_of(idx), entries[idx], jid, j.order_kind])
	for idx: int in jm._by_tile:
		if jm.get_job(jm._by_tile[idx]) == null and not tolerate_stale_tile_index:
			errs.append("QA: tile index %d points to missing job %s" % [idx, jm._by_tile[idx]])
	# Inventory
	var carriers := {}
	for it in ses.inventory.all_items():
		if not (it.kg > 0.0) or not is_finite(it.kg):
			errs.append("QA: item %s has kg %s" % [it.id, it.kg])
		match it.holder:
			Inventory.Holder.NPC:
				if it.kg > Inventory.CARRY_CAPACITY_KG + EPS:
					errs.append("QA: %s carries %.3f kg > capacity" % [it.holder_id, it.kg])
				if carriers.has(it.holder_id):
					errs.append("QA: %s carries two stacks" % it.holder_id)
				carriers[it.holder_id] = true
			Inventory.Holder.GROUND:
				if not ses.grid.in_bounds(it.tile):
					errs.append("QA: ground item %s out of bounds at %s" % [it.id, it.tile])
	# Stockpile bookings
	var per_tile := {}
	for b: Dictionary in ses.stockpiles.to_snapshot()["bookings"]:
		var t: Vector2i = b["tile"]
		if not ses.stockpiles.is_stockpile(t):
			errs.append("QA: booking %s on non-zone tile %s" % [b["job_id"], t])
		per_tile[t] = float(per_tile.get(t, 0.0)) + float(b["kg"])
	for t: Vector2i in per_tile:
		if absf(float(per_tile[t]) - ses.stockpiles.booked_kg(t)) > EPS:
			errs.append("QA: booked total mismatch on %s" % t)
		if float(per_tile[t]) > StockpileZones.TILE_CAPACITY_KG + EPS:
			errs.append("QA: tile %s overbooked %.1f kg" % [t, per_tile[t]])
	# NPCs
	for n in ses.colony.all_npcs():
		if not ses.grid.in_bounds(n.tile):
			errs.append("QA: %s out of bounds at %s" % [n.id, n.tile])
	if ses.buildings != null:
		errs.append_array(m3_invariants(ses))
	return errs


## M3: buildings stand on valid tiles with support; crate contents and
## bookings within capacity; crate items belong to a live crate; building
## orders still placeable and not overlapping designations.
static func m3_invariants(ses: WorldSession) -> Array[String]:
	var errs: Array[String] = []
	var b := ses.buildings
	var g := ses.grid
	for id in b.all_ids():
		var info := b.get_building(id)
		var d := b.def(info["key"])
		var r := b.footprint(info["key"], info["origin"])
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				var p := Vector2i(x, y)
				if g.get_tile(p) != TileRegistry.AIR or g.get_structure(p) != WorldGrid.Structure.NONE:
					errs.append("QA: building %s on a non-air / ladder tile %s" % [id, p])
				if b.building_at(p) != id:
					errs.append("QA: occupancy of %s at %s is '%s'" % [id, p, b.building_at(p)])
		if not b._has_support(d, r):
			errs.append("QA: building %s (%s) has no support" % [id, info["key"]])
		var mkg := 0.0
		for m in info["materials"]:
			mkg += float(info["materials"][m])
		if absf(mkg - d.kg) > EPS:
			errs.append("QA: building %s holds %.3f kg of materials, recipe %.3f" % [id, mkg, d.kg])
	if ses.crates != null:
		var cs := ses.crates
		for cid in cs.crate_ids():
			var cap := b.def(b.get_building(cid)["key"]).storage_kg
			var have := ses.inventory.crate_kg(cid)
			if have > cap + EPS:
				errs.append("QA: crate %s holds %.1f kg > capacity %.1f" % [cid, have, cap])
			if have + cs.booked_kg(cid) > cap + EPS:
				errs.append("QA: crate %s overbooked: %.1f stored + %.1f booked > %.1f" % [cid, have, cs.booked_kg(cid), cap])
		for bk: Dictionary in cs.to_snapshot()["bookings"]:
			if not cs.is_crate(bk["building_id"]):
				errs.append("QA: crate booking %s on non-crate %s" % [bk["job_id"], bk["building_id"]])
	if ses.build_orders != null:
		for o in ses.build_orders.orders():
			if not b.can_place(o["key"], o["origin"]).ok:
				errs.append("QA: building order %s at %s can no longer be placed" % [o["id"], o["origin"]])
			var fp := b.footprint(o["key"], o["origin"])
			for y in range(fp.position.y, fp.end.y):
				for x in range(fp.position.x, fp.end.x):
					if ses.designations.get_kind(Vector2i(x, y)) != DesignationMap.Kind.NONE:
						errs.append("QA: building order %s overlaps a designation at %s" % [o["id"], Vector2i(x, y)])
	return errs


## Rooms of the live (incrementally updated) RoomMap vs a full rebuild.
## Returns differences (empty = identical sets of tiles/type/buildings).
static func rooms_vs_rebuild(ses: WorldSession) -> Array[String]:
	var fresh := RoomMap.new(ses.grid, ses.buildings)
	var a := room_signature(ses.rooms)
	var b := room_signature(fresh)
	fresh.grid.tiles_changed.disconnect(fresh._on_changed)
	var errs: Array[String] = []
	for k: String in a:
		if not b.has(k):
			errs.append("QA: incremental room not in rebuild: %s" % k.left(120))
		elif a[k] != b[k]:
			errs.append("QA: room %s type/buildings %s vs rebuild %s" % [k.left(60), a[k], b[k]])
	for k: String in b:
		if not a.has(k):
			errs.append("QA: rebuild room missing incrementally: %s" % k.left(120))
	return errs


## {"<sorted tile indices>": "type|building ids"} for every room.
static func room_signature(rm: RoomMap) -> Dictionary:
	var out := {}
	for r in rm.all_rooms():
		var tiles := rm.room_tiles(r["id"])
		out[str(Array(tiles))] = "%s|%s" % [r["type"], ",".join(PackedStringArray(r["building_ids"]))]
	return out


func _watch_npcs() -> void:
	var t := now()
	for n in s.colony.all_npcs():
		# Idle-and-unstandable detector.
		if not n.is_moving() and not s.nav.can_stand(n.tile):
			_unstandable[n.id] = int(_unstandable.get(n.id, 0)) + 1
		else:
			_unstandable.erase(n.id)
		# Stuck detector: same job, same tile, same work progress for STUCK_TICKS.
		if n.job_id.is_empty():
			_npc_watch.erase(n.id)
			continue
		var j := s.jobs.get_job(n.job_id)
		var key := "%s|%s|%s|%.3f|%s|%s" % [n.job_id, n.tile, n.prev_tile, n.work_progress,
				j.phase if j != null else "", s.jobs.inventory.site_kg(n.job_id)]
		var w: Variant = _npc_watch.get(n.id)
		if w == null or w["key"] != key:
			_npc_watch[n.id] = {"key": key, "since": t}
		elif t - int(w["since"]) == STUCK_TICKS:
			stuck_reports.append("tick %d: %s stuck %d ticks on %s (%s)" % [t, n.id, STUCK_TICKS,
					s.jobs.describe_job(n.job_id), key])


# --- Random player actions ---------------------------------------------

func random_action() -> void:
	var total := 0
	for k: String in action_weights:
		total += int(action_weights[k])
	var r := rng.randi_range(1, total)
	for k: String in action_weights:
		r -= int(action_weights[k])
		if r <= 0:
			_do(k)
			actions_run += 1
			return


func _do(action: String) -> void:
	var g := s.grid
	var npc := _random_npc()
	var near := npc.tile if npc != null else Vector2i(g.width / 2, g.surface_y[g.width / 2] - 1)
	var res: Variant = null
	match action:
		"dig":
			var x := clampi(near.x + rng.randi_range(-14, 14), 1, g.width - 2)
			var y := clampi(g.surface_y[x] + rng.randi_range(-1, 6), 0, g.height - 1)
			var r := Rect2i(x, y, rng.randi_range(1, 4), rng.randi_range(1, 3))
			res = s.designations.designate(r, K.DIG, rng.randi_range(1, 9))
			_log("dig %s" % r)
		"ladder":
			var x := clampi(near.x + rng.randi_range(-8, 8), 1, g.width - 2)
			var y := clampi(near.y + rng.randi_range(-4, 4), 0, g.height - 1)
			var r := Rect2i(x, y, 1, rng.randi_range(1, 6))
			res = s.designations.designate(r, K.BUILD_LADDER, rng.randi_range(1, 9))
			_log("ladder %s" % r)
		"wall":
			var x := clampi(near.x + rng.randi_range(-8, 8), 1, g.width - 2)
			var y := clampi(near.y + rng.randi_range(-3, 1), 0, g.height - 1)
			var r := Rect2i(x, y, rng.randi_range(1, 3), 1)
			res = s.designations.designate(r, K.BUILD_WALL, rng.randi_range(1, 9))
			_log("wall %s" % r)
		"cancel":
			var t := _random_order_tile()
			if t != Vector2i(-1, -1):
				var r := Rect2i(t - Vector2i(1, 1), Vector2i(rng.randi_range(1, 4), rng.randi_range(1, 4)))
				res = s.designations.cancel(r)
				_log("cancel %s" % r)
		"priority":
			var t := _random_order_tile()
			if t != Vector2i(-1, -1):
				var r := Rect2i(t - Vector2i(2, 2), Vector2i(5, 5))
				var p := rng.randi_range(1, 9)
				res = s.designations.set_priority(r, p)
				_log("priority %s -> %d" % [r, p])
		"stock_add":
			var x := clampi(near.x + rng.randi_range(-12, 12), 1, g.width - 4)
			var r := Rect2i(x, near.y + rng.randi_range(-2, 1), rng.randi_range(1, 4), rng.randi_range(1, 2))
			res = s.stockpiles.designate(r)
			_log("stock_add %s" % r)
		"stock_remove":
			var zt := s.stockpiles.tiles()
			if not zt.is_empty():
				var t := zt[rng.randi_range(0, zt.size() - 1)]
				var r := Rect2i(t, Vector2i(rng.randi_range(1, 3), 1))
				res = s.stockpiles.remove(r)
				_log("stock_remove %s" % r)
		"move":
			if npc != null:
				var t := Vector2i(clampi(near.x + rng.randi_range(-15, 15), 0, g.width - 1),
						clampi(near.y + rng.randi_range(-4, 4), 0, g.height - 1))
				res = s.colony.command_move(npc.id, t)
				_log("move %s -> %s" % [npc.id, t])
		"stop":
			if npc != null:
				res = s.colony.command_stop(npc.id)
				_log("stop %s" % npc.id)
		"toggle":
			if npc != null:
				var w: StringName = Npc.WORK_KEYS[rng.randi_range(0, 2)]
				var on := rng.randf() < 0.7
				res = s.colony.set_work_enabled(npc.id, w, on)
				_log("toggle %s %s %s" % [npc.id, w, on])
		"dig_under_npc":
			if npc != null and allow_terrain:
				var r := Rect2i(npc.tile + Vector2i(rng.randi_range(-1, 1), 1), Vector2i.ONE)
				res = g.apply_edit(r, WorldGrid.Edit.DIG)
				_log("apply_edit DIG under %s %s" % [npc.id, r])
		"dig_under_stock":
			var zt := s.stockpiles.tiles()
			if not zt.is_empty() and allow_terrain:
				var t := zt[rng.randi_range(0, zt.size() - 1)]
				var r := Rect2i(t + Vector2i.DOWN, Vector2i.ONE)
				res = g.apply_edit(r, WorldGrid.Edit.DIG)
				_log("apply_edit DIG under stockpile %s" % r)
		"wall_over":
			if allow_terrain and allow_walls_over:
				var r := Rect2i(near + Vector2i(rng.randi_range(-3, 3), rng.randi_range(-2, 0)), Vector2i.ONE)
				res = g.apply_edit(r, WorldGrid.Edit.BUILD_WALL)
				_log("apply_edit WALL %s" % r)
		"remove_ladder":
			if allow_terrain:
				for i in 20:
					var p := Vector2i(clampi(near.x + rng.randi_range(-6, 6), 0, g.width - 1),
							clampi(near.y + rng.randi_range(-6, 6), 0, g.height - 1))
					if g.is_ladder(p):
						res = g.remove_structure(p)
						_log("remove_structure %s" % p)
						break
		"spawn_item":
			var x := clampi(near.x + rng.randi_range(-10, 10), 1, g.width - 2)
			var t := _feet_in_column(x)
			if t != Vector2i(-1, -1):
				var mat: StringName = [&"rock", &"dirt", &"iron_ore"][rng.randi_range(0, 2)]
				var kg := snappedf(rng.randf_range(1.0, 320.0), 0.25)
				if not s.inventory.spawn_ground(mat, kg, t).is_empty():
					qa_spawned_kg += kg
					_log("spawn %s %.2f kg at %s" % [mat, kg, t])
		"building":
			if s.build_orders != null:
				var keys: Array[StringName] = [&"crate", &"crate", &"bed", &"table", &"door"]
				var key := keys[rng.randi_range(0, keys.size() - 1)]
				var o := _random_floor_tile(near)
				if o != Vector2i(-1, -1):
					var r := s.build_orders.order_building(key, o, rng.randi_range(1, 9))
					res = r
					_log("order %s at %s -> %s" % [key, o, r.code if not r.ok else r.data["id"]])
		"carve_room":
			if allow_terrain:
				# Enclosed pocket below the surface (a room when <= 128 tiles); half of
				# them get a laddered shaft to the surface so NPCs can reach them.
				var x := clampi(near.x + rng.randi_range(-20, 20), 3, g.width - 12)
				var top: int = g.surface_y[x] + rng.randi_range(3, 12)
				var r := Rect2i(x, top, rng.randi_range(3, 9), rng.randi_range(3, 4))
				if r.end.y < g.height - 3:
					res = g.apply_edit(r, WorldGrid.Edit.DIG)
					var shaft := rng.randf() < 0.5
					if shaft:
						var sx := r.position.x
						var sy: int = g.surface_y[sx]
						g.apply_edit(Rect2i(sx, sy, 1, r.end.y - sy), WorldGrid.Edit.DIG)
						for y in range(sy, r.end.y):
							if g.can_place_structure(Vector2i(sx, y), WorldGrid.Structure.LADDER):
								g.apply_structure(Vector2i(sx, y), WorldGrid.Structure.LADDER)
					_log("carve room %s shaft %s" % [r, shaft])
		"deconstruct":
			var t := _random_decon_target(near)
			if t != Vector2i(-1, -1):
				res = s.designations.designate(Rect2i(t, Vector2i.ONE), K.DECONSTRUCT, rng.randi_range(1, 9))
				_log("deconstruct %s -> %s" % [t, (res as CommandResult).ok])
		"build_cancel":
			if s.build_orders != null and s.build_orders.count() > 0:
				var os := s.build_orders.orders()
				var o: Dictionary = os[rng.randi_range(0, os.size() - 1)]
				res = s.build_orders.cancel_at(Rect2i(o["origin"], Vector2i.ONE))
				_log("cancel building order %s" % o["id"])
		"build_priority":
			if s.build_orders != null and s.build_orders.count() > 0:
				var os := s.build_orders.orders()
				var o: Dictionary = os[rng.randi_range(0, os.size() - 1)]
				var p := rng.randi_range(1, 9)
				res = s.build_orders.set_priority(Rect2i(o["origin"], Vector2i.ONE), p)
				_log("building order %s priority %d" % [o["id"], p])
		"crate_filter":
			if s.crates != null:
				var cids := s.crates.crate_ids()
				if not cids.is_empty():
					var cid: String = cids[rng.randi_range(0, cids.size() - 1)]
					var all: Array[StringName] = [&"rock", &"dirt", &"iron_ore"]
					var f: Array[StringName] = []
					for m in all:
						if rng.randf() < 0.4:
							f.append(m)
					res = s.crates.set_filter(cid, f)
					_log("crate %s filter %s" % [cid, f])
		"dig_under_building":
			if allow_terrain and s.buildings != null and s.buildings.count() > 0:
				var bids := s.buildings.all_ids()
				var bid: String = bids[rng.randi_range(0, bids.size() - 1)]
				var info := s.buildings.get_building(bid)
				var r := Rect2i(info["origin"] + Vector2i.DOWN, Vector2i.ONE)
				res = g.apply_edit(r, WorldGrid.Edit.DIG)
				_log("apply_edit DIG under building %s %s" % [bid, r])
		"spawn_npc":
			if s.colony.count() < max_npcs:
				var t := _random_surface_feet(near.x, 10)
				if t != Vector2i(-1, -1):
					var n := s.colony.spawn_npc(t)
					_log("spawn_npc %s at %s" % [n.id, t])
	if res != null and res is CommandResult and not (res as CommandResult).ok:
		pass  # failures are fine (invalid selection etc.)


func _log(line: String) -> void:
	log_lines.append("t%d %s" % [now(), line])
	if log_lines.size() > LOG_KEEP:
		log_lines.remove_at(0)


func recent_log() -> String:
	return "\n".join(log_lines)


func _random_npc() -> Npc:
	var list := s.colony.all_npcs()
	if list.is_empty():
		return null
	return list[rng.randi_range(0, list.size() - 1)]


## A random air tile with a solid tile below it, near `near` or inside a
## carved pocket (scans a random column downwards).
func _random_floor_tile(near: Vector2i) -> Vector2i:
	var g := s.grid
	for i in 20:
		var x := clampi(near.x + rng.randi_range(-20, 20), 1, g.width - 3)
		var y0 := clampi(near.y + rng.randi_range(-4, 2), 3, g.height - 2)
		for y in range(y0, mini(g.height - 1, y0 + 18)):
			var p := Vector2i(x, y)
			if g.get_tile(p) == TileRegistry.AIR and g.is_solid_at(p + Vector2i.DOWN):
				return p
	return Vector2i(-1, -1)


## A random building tile, ladder or concrete wall near `near` (or none).
func _random_decon_target(near: Vector2i) -> Vector2i:
	var g := s.grid
	if s.buildings != null and s.buildings.count() > 0 and rng.randf() < 0.5:
		var bids := s.buildings.all_ids()
		var info := s.buildings.get_building(bids[rng.randi_range(0, bids.size() - 1)])
		return info["origin"]
	for i in 40:
		var p := Vector2i(clampi(near.x + rng.randi_range(-10, 10), 0, g.width - 1),
				clampi(near.y + rng.randi_range(-6, 6), 0, g.height - 1))
		if g.is_ladder(p) or g.get_tile(p) == TileRegistry.CONCRETE:
			return p
	return Vector2i(-1, -1)


func _random_order_tile() -> Vector2i:
	var e := s.designations.entries()
	if e.is_empty():
		return Vector2i(-1, -1)
	var keys := e.keys()
	var idx: int = keys[rng.randi_range(0, keys.size() - 1)]
	return Vector2i(idx % s.grid.width, idx / s.grid.width)


## First standable feet tile from the top of column x.
func _feet_in_column(x: int) -> Vector2i:
	for y in s.grid.height:
		var p := Vector2i(x, y)
		if s.grid.is_solid_at(p):
			return p + Vector2i.UP if s.nav.can_stand(p + Vector2i.UP) else Vector2i(-1, -1)
	return Vector2i(-1, -1)


func _random_surface_feet(cx: int, spread: int) -> Vector2i:
	for i in 30:
		var x := clampi(cx + rng.randi_range(-spread, spread), 1, s.grid.width - 2)
		var t := _feet_in_column(x)
		if t != Vector2i(-1, -1):
			return t
	return Vector2i(-1, -1)


# --- Save / load --------------------------------------------------------

## Saves the session (in memory via var_to_bytes, or through the real atomic
## file writer + load_world when dir != ""), loads it, compares, and continues
## with the loaded session. Returns problems found (empty = OK).
func save_load(dir: String = "") -> Array[String]:
	var errs: Array[String] = []
	var before := _summary(s)
	var r: CommandResult
	if dir.is_empty():
		var p := SaveService.build_payload(s)
		var p2: Variant = bytes_to_var(var_to_bytes(p))
		r = SaveService.session_from_payload(p2, s.meta, reg)
	else:
		var sr := SaveService.save(s, dir, SaveService.Kind.MANUAL)
		if not sr.ok:
			return ["save failed: %s" % sr.message]
		r = SaveService.load_world(dir, reg, s.meta)
	if not r.ok:
		return ["load failed: %s %s" % [r.message, r.data]]
	for k: String in r.data["dropped"]:
		if int(r.data["dropped"][k]) != 0:
			errs.append("load dropped %d %s entries" % [r.data["dropped"][k], k])
	var l: WorldSession = r.data["session"]
	var after := _summary(l)
	for k: String in before:
		# Variant == compares dictionaries by content (key order irrelevant).
		if typeof(before[k]) != typeof(after[k]) or before[k] != after[k]:
			errs.append("after load %s: %s -> %s" % [k, before[k], after[k]])
	var inv_errs := l.jobs.check_invariants()
	inv_errs.append_array(l.inventory.check_conservation())
	inv_errs.append_array(extra_invariants(l))
	for e in inv_errs:
		errs.append("after load: " + e)
	s = l
	_npc_watch.clear()
	_unstandable.clear()
	loads_done += 1
	_log("save/load (%s)" % ("file" if not dir.is_empty() else "memory"))
	return errs


## What must survive a save/load unchanged.
static func _summary(ses: WorldSession) -> Dictionary:
	var kg := {}
	var totals := ses.inventory.total_kg_by_material()
	for m in totals:
		kg[String(m)] = snappedf(float(totals[m]), 0.001)
	var sp := {}
	for m in ses.inventory.spawned_kg_by_material():
		sp[String(m)] = snappedf(float(ses.inventory.spawned_kg_by_material()[m]), 0.001)
	var co := {}
	for m in ses.inventory.consumed_kg_by_material():
		co[String(m)] = snappedf(float(ses.inventory.consumed_kg_by_material()[m]), 0.001)
	var carried := {}
	var npc_jobs := {}
	for n in ses.colony.all_npcs():
		var c := ses.inventory.carried_by(n.id)
		carried[n.id] = c.id if c != null else ""
		npc_jobs[n.id] = n.job_id
	var order_jobs := 0
	var workers := {}
	for j in ses.jobs.all_jobs():
		if j.kind != Job.KIND_HAUL:
			order_jobs += 1
		if not j.worker_id.is_empty():
			workers[j.id] = j.worker_id
	var site := {}
	for it in ses.inventory.all_items():
		if it.holder == Inventory.Holder.SITE:
			site[it.holder_id] = snappedf(float(site.get(it.holder_id, 0.0)) + it.kg, 0.001)
	var m3 := {}
	if ses.buildings != null:
		m3["buildings"] = ses.buildings.to_snapshot()
		m3["build_orders"] = ses.build_orders.to_snapshot()
		m3["crate_filters"] = ses.crates.to_snapshot()["filters"]
		var ck := {}
		for cid in ses.crates.crate_ids():
			ck[cid] = snappedf(ses.inventory.crate_kg(cid), 0.001)
		m3["crate_kg"] = ck
		m3["rooms"] = room_signature(ses.rooms)  # rooms are rebuilt on load (not saved)
	return {
		"m3": m3,
		"kg_by_material": kg, "spawned": sp, "consumed": co,
		"item_count": ses.inventory.all_items().size(),
		"npc_count": ses.colony.count(),
		"orders": ses.designations.count(),
		"order_jobs": order_jobs,
		"zones": ses.stockpiles.count(),
		"world_hash": ses.grid.world_hash(),
		"carried": carried,
		"npc_jobs": npc_jobs,
		"job_workers": workers,
		"site_kg": site,
		"tick": ses.clock.tick_index,
	}
