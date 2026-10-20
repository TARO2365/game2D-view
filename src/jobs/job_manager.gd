class_name JobManager
extends RefCounted
## Job lifecycle and ALL reservations (M2 contract §1, §7): job <-> NPC,
## item <-> job and stockpile capacity <-> job. Jobs come from player orders
## (DesignationMap: dig, build wall, build ladder) and from loose ground items
## (haul to a stockpile).
##
## Spec §3 invariant: NPC AI never touches Inventory / WorldGrid. Colony moves
## NPCs and calls try_assign() / drive() / find_path_for() /
## report_unreachable(); every pick up, delivery, dig and build is executed here.
##
## Work positions (reach): an NPC with feet F can work on tile T when
## |T.x - F.x| <= 1 and F.y - clearance <= T.y <= F.y + 1; wall builds also
## need T outside the NPC's own body; dig targets must touch a passable tile.
##
## Unreachable: a failed path search marks the job for THAT NPC for
## UNREACHABLE_RETRY_TICKS (or until terrain near the job changes). When every
## eligible NPC is blocked, or the order has no work position at all, the job
## itself is unreachable (is_unreachable(), overlay). An exhaustive failed
## search also records the NPC's whole reachable region (it is confined, e.g.
## in a pit), so further jobs outside it are rejected without searching.
##
## Per-tick work is bounded: designations and items are only scanned on their
## change signals or at NORMAL cadence (hauling); open jobs are bucketed by
## chunk and assignment scans rings of chunks around the NPC for the top
## ASSIGN_CANDIDATES (priority desc, then Manhattan distance); every path
## search takes a unit of the shared NavGrid budget.

signal jobs_changed

const DIG_TICKS_PER_HARDNESS := 10      # PLACEHOLDER: dirt (1.0) = 1 s at 1x
const UNREACHABLE_RETRY_TICKS := 100    # PLACEHOLDER
const UNREACHABLE_AREA_MARGIN := 4      # PLACEHOLDER: tiles_changed this close re-opens a job
const HAUL_PRIORITY := 5                # PLACEHOLDER (same as DesignationMap.DEFAULT_PRIORITY)
const HAUL_SCAN_PER_CADENCE := 32       # PLACEHOLDER loose items examined per NORMAL cadence
const HAUL_RETRY_TICKS := 50            # PLACEHOLDER: re-check items that had no drop tile
const ASSIGN_CANDIDATES := 8            # PLACEHOLDER jobs considered per assignment attempt
const REGION_MAX_TILES := 600           # PLACEHOLDER: larger confined regions are not cached
const REGION_CACHE_SIZE := 16           # PLACEHOLDER: recorded regions shared between NPCs
const SWEEP_PER_TICK := 16              # PLACEHOLDER: open jobs checked per tick for "nobody can reach"
const STEP_ASIDE_AFTER_TICKS := 20      # PLACEHOLDER: wall blocked this long -> blocker steps aside
const CLEAR_RADIUS := 4                 # PLACEHOLDER: where stacks cleared off a wall site go
const DROP_BLOCK_MARGIN := 8            # PLACEHOLDER: terrain change this close re-allows a stockpile tile
const GEO_UNREACHABLE := 1 << 60        # "until terrain changes" (order has no work position)
const LADDER_REFUND_MATERIAL := &"dirt"  # PLACEHOLDER: ladder material is not tracked per tile
const ID_CATEGORY := &"job"
const NO_TILE := Vector2i(-1, -1)
const KG_EPSILON := 0.001

const REASON_NO_MATERIAL := "no material"
const REASON_BLOCKED := "blocked by NPC"
const REASON_ITEMS_IN_WAY := "items in the way"
const REASON_UNREACHABLE := "unreachable"

const ACTION_NONE := &"none"     # no job (finished / released)
const ACTION_GOTO := &"goto"     # walk to one of data["goals"]
const ACTION_WORK := &"work"     # worked one tick
const ACTION_WAIT := &"wait"     # nothing to do this tick, keep the job

var grid: WorldGrid
var designations: DesignationMap
var inventory: Inventory
var stockpiles: StockpileZones
var nav: NavGrid
var ids: StableIdAllocator

## Weak: Colony holds JobManager strongly; a strong back-reference would be
## a RefCounted cycle (leak).
var _colony_ref: WeakRef = null
var _colony: Colony:
	get:
		return _colony_ref.get_ref() as Colony if _colony_ref != null else null

## M3 (optional: null in M2-only setups and tests).
var buildings: Buildings = null
var crates: CrateStorage = null
var build_orders: BuildOrders = null

var _jobs: Dictionary = {}           # job id -> Job (creation order)
var _by_tile: Dictionary = {}        # tile index -> job id (dig / build / deconstruct)
var _by_order: Dictionary = {}       # build order id -> building job id
var _decon_by_building: Dictionary = {}  # building id -> deconstruct job id
var _job_tiles: Dictionary = {}      # building deconstruct job id -> [designated tile indices]
## Crate index kept from items_changed / crates_changed (M3-QA-6: never scan
## every item or every building per candidate in hot loops).
var _item_crate: Dictionary = {}     # item id in a crate -> [crate id, kg]
var _crate_items_idx: Dictionary = {}  # crate id -> {item id: true}
var _crate_kg_idx: Dictionary = {}   # crate id -> kg stored
var _crate_list: Array = []          # [{id, tile, storage, filter: Array}] (crate id order)
var _crate_list_valid: bool = false
## Material each ladder tile was built from (tile index -> {material: kg}),
## refunded by deconstruction (M3-QA-1). Saved in the jobs snapshot.
var _ladder_mats: Dictionary = {}
var _item_res: Dictionary = {}       # reserved ground item id -> job id
var _site_kg: Dictionary = {}        # build job id -> kg delivered (mirror of Inventory)
var _ground: Dictionary = {}         # ground item id -> chunk index (cache from items_changed)
var _ground_by_chunk: Dictionary = {}  # chunk index -> {ground item id: true}
var _region_cache: Array = []        # [{tiles, reach, bbox}] recorded confined regions
var _sweep_ids: Array = []           # job ids of the current unreachable sweep pass
var _sweep_i: int = 0
var _wall_orders: int = 0            # live BUILD_WALL jobs (= wall orders)
var _open_chunks: Dictionary = {}    # chunk index -> {job id: Job} (no worker, not unreachable)
var _prio_count := PackedInt32Array()  # open jobs per priority 0..9
var _marked_chunks: Dictionary = {}  # chunk index -> {job id: true} (has unreachable marks)
var _reopen_at: Dictionary = {}      # tick -> Array of job ids whose unreachable flag expires
var _haul_queue: Array[String] = []  # loose items to consider for hauling
var _queued: Dictionary = {}         # item id -> true while in _haul_queue
var _haul_retry: Dictionary = {}     # item id -> true (no stockpile space last time)
var _item_unreachable: Dictionary = {}  # item id -> tick until it is skipped
var _geom_version: int = 0
var _tick: int = 0
var _last_update_tick: int = 0
var _last_retry_tick: int = 0
var _reconcile_pending: bool = false
var _chunks_x: int = 1


## The M3 parts (buildings, crates, build orders) are optional so M2 setups
## keep working; WorldSession passes all of them.
func _init(world_grid: WorldGrid, designation_map: DesignationMap, inv: Inventory,
		zones: StockpileZones, nav_grid: NavGrid, id_alloc: StableIdAllocator,
		world_buildings: Buildings = null, crate_storage: CrateStorage = null,
		orders: BuildOrders = null) -> void:
	grid = world_grid
	designations = designation_map
	inventory = inv
	stockpiles = zones
	nav = nav_grid
	ids = id_alloc
	buildings = world_buildings
	crates = crate_storage
	build_orders = orders
	_chunks_x = grid.chunks_x()
	_prio_count.resize(DesignationMap.MAX_PRIORITY + 1)
	designations.designations_changed.connect(_on_designations_changed)
	grid.tiles_changed.connect(_on_tiles_changed)
	inventory.items_changed.connect(_on_items_changed)
	stockpiles.zones_changed.connect(_on_zones_changed)
	if buildings != null:
		buildings.building_lost.connect(_on_building_lost)
	if crates != null:
		crates.crates_changed.connect(_on_crates_changed)
	if build_orders != null:
		build_orders.orders_changed.connect(_on_orders_changed)
	_rebuild_ground()
	_sync_all_designations()
	_sync_orders()


## Called by Colony's constructor (Colony is created after JobManager, §7).
func attach_colony(colony: Colony) -> void:
	_colony_ref = weakref(colony)


# --- Contract API -------------------------------------------------------

func update(tick: int) -> void:
	_tick = tick
	if _reconcile_pending:
		revalidate()
	_expire_unreachable(tick)
	_sweep_unreachable(tick)
	if SimulationClock.is_cadence_due(SimulationClock.Cadence.NORMAL, tick):
		_haul_scan(tick)


func job_count() -> int:
	return _jobs.size()


func get_job(job_id: String) -> Job:
	return _jobs.get(job_id)


## All jobs in creation order.
func all_jobs() -> Array[Job]:
	var out: Array[Job] = []
	for j: Job in _jobs.values():
		out.append(j)
	return out


## Job on an order tile (dig / build / deconstruct, or a building order's
## footprint), or null.
func job_at(tile: Vector2i) -> Job:
	if not grid.in_bounds(tile):
		return null
	var j: Job = _jobs.get(_by_tile.get(_idx(tile), ""))
	if j == null and build_orders != null:
		var o := build_orders.order_at(tile)
		if not o.is_empty():
			j = _jobs.get(_by_order.get(o["id"], ""))
	return j


func describe_job(job_id: String) -> String:
	var job: Job = _jobs.get(job_id)
	if job == null:
		return ""
	var text := ""
	match job.kind:
		Job.KIND_DIG:
			text = "Dig (%d, %d)" % [job.tile.x, job.tile.y]
		Job.KIND_BUILD:
			var what := "wall" if job.order_kind == DesignationMap.Kind.BUILD_WALL else "ladder"
			text = "Build %s (%d, %d)" % [what, job.tile.x, job.tile.y]
		Job.KIND_HAUL:
			var it := inventory.get_item(job.carried_id if not job.carried_id.is_empty() else job.item_id)
			text = "Haul %s %.0f kg" % [it.material, it.kg] if it != null else "Haul"
		Job.KIND_BUILDING:
			text = "Build %s (%d, %d)" % [job.building_key, job.tile.x, job.tile.y]
		Job.KIND_DECONSTRUCT:
			var what := "wall"
			if not job.order_id.is_empty() and buildings != null:
				what = String(buildings.get_building(job.order_id).get("key", "building"))
			elif grid.is_ladder(job.tile):
				what = "ladder"
			text = "Deconstruct %s (%d, %d)" % [what, job.tile.x, job.tile.y]
	if not job.wait_reason.is_empty():
		text += " - " + job.wait_reason
	return text


## An order exists on tile but no NPC can currently reach it (overlay).
func is_unreachable(tile: Vector2i) -> bool:
	var job := job_at(tile)
	return job != null and job.unreachable_until > _tick


## Empty = every reservation invariant holds (QA calls this).
func check_invariants() -> Array[String]:
	var errors: Array[String] = []
	var colony := _colony
	var claimed := {}
	for job: Job in _jobs.values():
		for iid: String in [job.item_id, job.carried_id]:
			if iid.is_empty():
				continue
			if claimed.has(iid):
				errors.append("item %s claimed by %s and %s" % [iid, claimed[iid], job.id])
			claimed[iid] = job.id
		if not job.item_id.is_empty():
			var it := inventory.get_item(job.item_id)
			if it == null or not (it.holder == Inventory.Holder.GROUND
					or (it.holder == Inventory.Holder.CRATE and job.needs_material())):
				errors.append("%s reserves %s which is not on the ground / in a crate" % [job.id, job.item_id])
			if _item_res.get(job.item_id, "") != job.id:
				errors.append("%s item %s missing from reservation table" % [job.id, job.item_id])
		if not job.carried_id.is_empty():
			var c := inventory.get_item(job.carried_id)
			if c == null or c.holder != Inventory.Holder.NPC or c.holder_id != job.worker_id \
					or job.worker_id.is_empty():
				errors.append("%s carried item %s is not held by its worker '%s'" % [job.id, job.carried_id, job.worker_id])
		if not job.worker_id.is_empty() and colony != null:
			var npc := colony.get_npc(job.worker_id)
			if npc == null:
				errors.append("%s worker %s does not exist" % [job.id, job.worker_id])
			elif npc.job_id != job.id:
				errors.append("%s worker %s works on '%s'" % [job.id, job.worker_id, npc.job_id])
		if job.is_done():
			errors.append("%s is done but still listed" % job.id)
		match job.kind:
			Job.KIND_HAUL:
				if job.item_id.is_empty() and job.carried_id.is_empty():
					errors.append("haul %s has no item" % job.id)
				if crates != null and not crates.booked_crate(job.id).is_empty() \
						and stockpiles.booked_tile(job.id) != NO_TILE:
					errors.append("haul %s holds a crate and a zone booking" % job.id)
			Job.KIND_BUILDING:
				if build_orders == null or build_orders.get_order(job.order_id).is_empty():
					errors.append("%s: building order %s is gone" % [job.id, job.order_id])
				elif _by_order.get(job.order_id, "") != job.id:
					errors.append("%s missing from order index" % job.id)
			Job.KIND_DECONSTRUCT:
				if designations.get_kind(job.tile) != DesignationMap.Kind.DECONSTRUCT:
					errors.append("%s has no deconstruct order at %s" % [job.id, job.tile])
				if not job.order_id.is_empty():
					if buildings == null or buildings.get_building(job.order_id).is_empty():
						errors.append("%s: building %s is gone" % [job.id, job.order_id])
					elif _decon_by_building.get(job.order_id, "") != job.id:
						errors.append("%s missing from building index" % job.id)
				if _by_tile.get(_idx(job.tile), "") != job.id:
					errors.append("%s missing from tile index" % job.id)
			_:
				if designations.get_kind(job.tile) != job.order_kind:
					errors.append("%s has no matching order at %s" % [job.id, job.tile])
				if _by_tile.get(_idx(job.tile), "") != job.id:
					errors.append("%s missing from tile index" % job.id)
		if job.needs_material() and absf(_site(job) - inventory.site_kg(job.id)) > KG_EPSILON:
			errors.append("%s site kg mirror %.3f != %.3f" % [job.id, _site(job), inventory.site_kg(job.id)])
		var should_open := job.worker_id.is_empty() and job.unreachable_until < 0
		if job._open != should_open:
			errors.append("%s open-bucket state %s, expected %s" % [job.id, job._open, should_open])
	for iid: String in _item_res:
		var j: Job = _jobs.get(_item_res[iid])
		if j == null or j.item_id != iid:
			errors.append("stale reservation of %s by %s" % [iid, _item_res[iid]])
	if colony != null:
		var per_job := {}
		for npc in colony.all_npcs():
			if not npc.job_id.is_empty():
				per_job[npc.job_id] = int(per_job.get(npc.job_id, 0)) + 1
				var j: Job = _jobs.get(npc.job_id)
				if j == null:
					errors.append("%s works on missing job %s" % [npc.id, npc.job_id])
				elif j.worker_id != npc.id:
					errors.append("%s claims %s whose worker is '%s'" % [npc.id, npc.job_id, j.worker_id])
			var c := inventory.carried_by(npc.id)
			if c != null:
				var j2: Job = _jobs.get(npc.job_id)
				if j2 == null or j2.carried_id != c.id:
					errors.append("%s carries %s outside its job" % [npc.id, c.id])
		for jid: String in per_job:
			if per_job[jid] > 1:
				errors.append("job %s has %d workers" % [jid, per_job[jid]])
	var snap := stockpiles.to_snapshot()
	for b: Dictionary in snap["bookings"]:
		var hj: Job = _jobs.get(b["job_id"])
		if hj == null or hj.kind != Job.KIND_HAUL:
			errors.append("booking by %s which is not a haul job" % b["job_id"])
	if crates != null:
		for b: Dictionary in crates.to_snapshot()["bookings"]:
			var cj: Job = _jobs.get(b["job_id"])
			if cj == null or cj.kind != Job.KIND_HAUL:
				errors.append("crate booking by %s which is not a haul job" % b["job_id"])
	if build_orders != null:
		for o in build_orders.orders():
			var bj: Job = _jobs.get(_by_order.get(o["id"], ""))
			if bj == null or bj.order_id != o["id"]:
				errors.append("building order %s has no job" % o["id"])
	var crate_set := {}
	if crates != null:
		for cid in crates.crate_ids():
			crate_set[cid] = true
	for it in inventory.all_items():
		if it.holder == Inventory.Holder.SITE:
			var sj: Job = _jobs.get(it.holder_id)
			if sj == null or not sj.needs_material():
				errors.append("site item %s belongs to missing build job %s" % [it.id, it.holder_id])
		elif it.holder == Inventory.Holder.NPC and colony != null and colony.get_npc(it.holder_id) == null:
			errors.append("item %s held by missing NPC %s" % [it.id, it.holder_id])
		elif it.holder == Inventory.Holder.CRATE and crates != null and not crate_set.has(it.holder_id):
			errors.append("item %s in missing crate %s" % [it.id, it.holder_id])
	return errors


# --- Colony-facing API --------------------------------------------------

## Finds the best job for an idle NPC (priority desc, then Manhattan
## distance), checks reachability with path searches from the shared budget
## and claims it atomically. data: {"job_id", "path": Array[Vector2i]}.
## Failure codes: busy, no_budget (retry next tick), no_job.
func try_assign(npc: Npc, tick: int) -> CommandResult:
	_tick = tick
	if not npc.job_id.is_empty():
		return CommandResult.failure(&"busy", "%s already has a job" % npc.id)
	if nav.budget_left(tick) <= 0:
		return CommandResult.failure(&"no_budget", "Path budget used up this tick")
	_adopt_cached_region(npc)
	for job in _top_candidates(npc, tick):
		if not job._open:
			continue  # changed by an earlier candidate (e.g. material taken over)
		var plan := _first_goals(job, npc)
		if plan.has("reason"):
			var reason: String = plan["reason"]
			if reason == REASON_UNREACHABLE:
				_set_job_unreachable(job, tick, true)  # no work position at all
			elif reason == REASON_NO_MATERIAL:
				job.wait_reason = REASON_NO_MATERIAL
			else:
				_mark(job, npc, tick)
			continue
		var goals: Array[Vector2i] = plan["goals"]
		var path: Array[Vector2i] = []
		if not goals.has(npc.tile):
			if npc._region_valid and not _any_in_region(goals, npc):
				_mark(job, npc, tick)
				continue
			if not nav.consume_budget(tick):
				return CommandResult.failure(&"no_budget", "Path budget used up this tick")
			path = find_path_for(npc, goals)
			if path.is_empty():
				_mark(job, npc, tick)
				continue
		_assign(job, npc, plan.get("item_id", ""))
		return CommandResult.success({"job_id": job.id, "path": path})
	return CommandResult.failure(&"no_job", "No reachable job")


## Path search for an NPC (the caller has taken budget). An exhaustive
## failure records the NPC's reachable region.
func find_path_for(npc: Npc, goals: Array[Vector2i]) -> Array[Vector2i]:
	var path := nav.find_path(npc.tile, goals)
	if path.is_empty() and nav.last_exhausted:
		_store_region(npc, nav.last_region())
	return path


## Advances the NPC's job by one tick when it is not moving. Returns
## {"action": ACTION_*, "goals": Array[Vector2i] (goto only)}.
func drive(npc: Npc, tick: int) -> Dictionary:
	_tick = tick
	var job: Job = _jobs.get(npc.job_id)
	if job == null or job.worker_id != npc.id:
		if _colony != null and not npc.job_id.is_empty():
			_colony._on_job_released(npc)
		return {"action": ACTION_NONE}
	match job.kind:
		Job.KIND_DIG:
			return _drive_dig(job, npc)
		Job.KIND_BUILD, Job.KIND_BUILDING:
			return _drive_build(job, npc)
		Job.KIND_DECONSTRUCT:
			return _drive_deconstruct(job, npc)
		Job.KIND_HAUL:
			return _drive_haul(job, npc)
	return {"action": ACTION_NONE}


## Called by Colony between path steps: true if the walk's destination is no
## longer useful for the job (job gone, haul booking lost, work positions
## changed), so the NPC should stop and ask drive() again.
func needs_new_route(npc: Npc) -> bool:
	var job: Job = _jobs.get(npc.job_id)
	if job == null or job.worker_id != npc.id:
		return true
	if npc._path.is_empty():
		return false
	var dest: Vector2i = npc._path[npc._path.size() - 1]
	if job.phase == Job.PHASE_FETCH and not job.item_id.is_empty():
		var it := inventory.get_item(job.item_id)
		if it == null or _item_pos(it) != job._fetch_tile:
			return true  # the stack moved (fell, crate emptied) or is gone
	match job.kind:
		Job.KIND_HAUL:
			if job.phase != Job.PHASE_DELIVER:
				return false
			var bc := _booked_crate(job)
			if not bc.is_empty():
				var c := inventory.get_item(job.carried_id)
				if c != null and not crates.accepts(bc, c.material):
					return true  # filter changed: stop and re-book
			return _haul_target(job) == NO_TILE
		Job.KIND_DIG, Job.KIND_DECONSTRUCT:
			return not _work_goals(job).has(dest)
		Job.KIND_BUILD, Job.KIND_BUILDING:
			if job.phase == Job.PHASE_DELIVER or job.phase == Job.PHASE_WORK:
				return not _work_goals(job).has(dest)
	return false


## Colony found no path to the goals drive() returned.
func report_unreachable(npc: Npc, tick: int) -> void:
	_tick = tick
	var job: Job = _jobs.get(npc.job_id)
	if job == null or job.worker_id != npc.id:
		return
	match job.kind:
		Job.KIND_HAUL:
			var iid := job.carried_id if not job.carried_id.is_empty() else job.item_id
			if job.phase == Job.PHASE_DELIVER:
				# This NPC cannot reach that stockpile tile: never haul there again
				# until terrain near it changes (no pick-up/drop loop).
				var bt := _haul_target(job)
				if bt != NO_TILE:
					npc._blocked_drops[_idx(bt)] = true
			_unassign(job)  # deletes the haul job, drops what it carried here
			_set_item_unreachable(iid, tick)
		Job.KIND_BUILD, Job.KIND_BUILDING:
			if job.phase == Job.PHASE_FETCH and not job.item_id.is_empty():
				# The material is out of reach, not the site: try another stack.
				_set_item_unreachable(job.item_id, tick)
				_release_item(job)
				return
			_unassign(job)
			_mark(job, npc, tick)
		_:
			_unassign(job)
			_mark(job, npc, tick)


## NPCs were added or became eligible for more work: jobs that were
## unreachable only because every NPC was blocked are offered again.
func on_npcs_changed() -> void:
	for job: Job in _jobs.values():
		if job.unreachable_until > _tick and not job._geo_unreachable \
				and not _all_blocked(job, _tick):
			job.unreachable_until = -1
			if job.wait_reason == REASON_UNREACHABLE:
				job.wait_reason = ""
			_refresh_open(job)


## The NPC fell (terrain vanished under it): its current work step restarts.
func on_npc_fell(npc: Npc) -> void:
	npc.work_progress = 0.0
	var job: Job = _jobs.get(npc.job_id)
	if job != null and job.worker_id == npc.id and job.phase == Job.PHASE_WORK:
		job.work_ticks = 0


## Releases the NPC's job cleanly (carried item dropped where it stands, all
## reservations released; dig/build orders stay for other NPCs).
## Returns the released job id ("" if none).
func release_npc(npc: Npc) -> String:
	var job: Job = _jobs.get(npc.job_id)
	if job == null or job.worker_id != npc.id:
		var c := inventory.carried_by(npc.id)
		if c != null:
			_put_down(npc.id, npc.tile)
		if _colony != null and not npc.job_id.is_empty():
			_colony._on_job_released(npc)
		return ""
	var jid := job.id
	_unassign(job)
	return jid


# --- Persistence --------------------------------------------------------

func to_snapshot() -> Dictionary:
	var out: Array = []
	for job: Job in _jobs.values():
		out.append(job.to_dict())
	var ladders: Array = []
	var keys := _ladder_mats.keys()
	keys.sort()
	for idx: int in keys:
		var t := _tile_of(idx)
		if not grid.is_ladder(t):
			continue  # stale (ladder gone without a deconstruct job)
		var mats := {}
		for m: StringName in _ladder_mats[idx]:
			mats[String(m)] = float(_ladder_mats[idx][m])
		ladders.append({"tile": t, "materials": mats})
	return {"jobs": out, "ladders": ladders}


## Restores jobs and re-validates every reservation against Inventory,
## StockpileZones and (if attached) Colony; anything inconsistent is released.
## Orders without a job get a new one. Load Colony BEFORE JobManager (or call
## revalidate() after both are loaded). Returns the number of dropped entries.
func load_snapshot(s: Dictionary) -> int:
	_jobs.clear()
	_by_tile.clear()
	_by_order.clear()
	_decon_by_building.clear()
	_job_tiles.clear()
	_item_res.clear()
	_site_kg.clear()
	_open_chunks.clear()
	_prio_count.fill(0)
	_marked_chunks.clear()
	_reopen_at.clear()
	_haul_queue.clear()
	_queued.clear()
	_haul_retry.clear()
	_item_unreachable.clear()
	_region_cache.clear()
	_wall_orders = 0
	nav.invalidate_all()
	_geom_version += 1
	_rebuild_ground()
	var dropped := 0
	_ladder_mats.clear()
	var lad_v: Variant = s.get("ladders", [])  # absent in M2/early M3 saves: dirt refund
	if typeof(lad_v) == TYPE_ARRAY:
		for e: Variant in lad_v:
			if not _load_ladder(e):
				dropped += 1
	var dropped_tiles := {}  # job id -> tile (to return orphan site items)
	var carried_claims := {}  # carried item id -> job id
	var list_v: Variant = s.get("jobs")
	if typeof(list_v) == TYPE_ARRAY:
		for e: Variant in list_v:
			var job := Job.from_dict(e)
			if job == null:
				dropped += 1
				continue
			if _jobs.has(job.id) or not grid.in_bounds(job.tile) or not _restore_job(job, carried_claims):
				dropped += 1
				dropped_tiles[job.id] = job.tile
				continue
	# Site materials: mirror for live build jobs; orphans go back to the ground.
	var orphan_sites := {}
	for it in inventory.all_items():
		if it.holder == Inventory.Holder.SITE:
			var sj: Job = _jobs.get(it.holder_id)
			if sj == null or not sj.needs_material():
				orphan_sites[it.holder_id] = true
			else:
				_site_kg[sj.id] = float(_site_kg.get(sj.id, 0.0)) + it.kg
	for jid: String in orphan_sites:
		var t: Vector2i = dropped_tiles.get(jid, _fallback_tile())
		inventory.return_site_to_ground(jid, _landing(t))
	# Bookings must belong to a live haul job; a haul holds at most one.
	for b: Dictionary in stockpiles.to_snapshot()["bookings"]:
		var hj: Job = _jobs.get(b["job_id"])
		if hj == null or hj.kind != Job.KIND_HAUL:
			stockpiles.release(b["job_id"])
	if crates != null:
		for b: Dictionary in crates.to_snapshot()["bookings"]:
			var cj: Job = _jobs.get(b["job_id"])
			if cj == null or cj.kind != Job.KIND_HAUL:
				crates.release(b["job_id"])
			else:
				stockpiles.release(cj.id)  # the crate booking wins
	_sync_all_designations()
	_sync_orders()
	_reconcile_pending = true
	if _colony != null:
		revalidate()
	_queue_all_loose()
	jobs_changed.emit()
	return dropped


func _load_ladder(e: Variant) -> bool:
	if typeof(e) != TYPE_DICTIONARY:
		return false
	var d: Dictionary = e
	var t: Variant = d.get("tile")
	var m_v: Variant = d.get("materials")
	if typeof(t) != TYPE_VECTOR2I or typeof(m_v) != TYPE_DICTIONARY or not grid.is_ladder(t):
		return false
	var mats := {}
	for m: Variant in m_v:
		var kg: Variant = (m_v as Dictionary)[m]
		if (typeof(m) == TYPE_STRING or typeof(m) == TYPE_STRING_NAME) and not String(m).is_empty() \
				and (typeof(kg) == TYPE_FLOAT or typeof(kg) == TYPE_INT) and float(kg) > 0.0:
			mats[StringName(m)] = float(kg)
	if mats.is_empty():
		return false
	_ladder_mats[_idx(t)] = mats
	return true


## Reconciles job <-> NPC links and carried items with Colony (after loads).
func revalidate() -> void:
	_reconcile_pending = false
	var colony := _colony
	if colony == null:
		return
	for job: Job in _jobs.values():
		if job.worker_id.is_empty():
			continue
		var npc := colony.get_npc(job.worker_id)
		if npc != null and npc.job_id == job.id:
			continue
		if not job.carried_id.is_empty():
			var it := inventory.get_item(job.carried_id)
			if it != null and it.holder == Inventory.Holder.NPC:
				_put_down(it.holder_id, npc.tile if npc != null else _landing(job.tile))
			job.carried_id = ""
		job.worker_id = ""
		if job.kind == Job.KIND_HAUL:
			_delete_job(job)
		else:
			_release_item(job)
			job.phase = Job.PHASE_OPEN
			_refresh_open(job)
	for npc in colony.all_npcs():
		if not npc.job_id.is_empty():
			var j: Job = _jobs.get(npc.job_id)
			if j == null or j.worker_id != npc.id:
				colony._on_job_released(npc)
		var c := inventory.carried_by(npc.id)
		if c != null:
			var j2: Job = _jobs.get(npc.job_id)
			if j2 == null or j2.carried_id != c.id:
				_put_down(npc.id, npc.tile)
	for it in inventory.all_items():
		if it.holder == Inventory.Holder.NPC and colony.get_npc(it.holder_id) == null:
			_put_down(it.holder_id, _fallback_tile())
	jobs_changed.emit()


# --- Driving jobs ------------------------------------------------------

func _drive_dig(job: Job, npc: Npc) -> Dictionary:
	var goals := _work_goals(job)
	if goals.is_empty():
		_give_up(job, REASON_UNREACHABLE)
		return {"action": ACTION_NONE}
	if not goals.has(npc.tile):
		return {"action": ACTION_GOTO, "goals": goals}
	job.phase = Job.PHASE_WORK
	job.work_ticks += 1
	var total := _dig_ticks(job.tile)
	npc.work_progress = minf(1.0, float(job.work_ticks) / total)
	if job.work_ticks >= total:
		_complete_dig(job)
		return {"action": ACTION_NONE}
	return {"action": ACTION_WORK}


func _drive_build(job: Job, npc: Npc) -> Dictionary:
	var rec := _recipe(job)
	if rec.is_empty():
		_cancel(job)
		return {"action": ACTION_NONE}
	var need := float(rec["kg"])
	for _step in 4:  # chain phase changes within one tick (bounded)
		match job.phase:
			Job.PHASE_FETCH, Job.PHASE_OPEN:
				if not job.carried_id.is_empty():
					job.phase = Job.PHASE_DELIVER
					continue
				if _site(job) + KG_EPSILON >= need:
					job.phase = Job.PHASE_WORK
					continue
				job.phase = Job.PHASE_FETCH
				var it := _reserved_item(job)
				if it == null:
					_release_item(job)
					var nid := _find_material(job, npc)
					if nid.is_empty():
						_give_up(job, REASON_NO_MATERIAL)
						return {"action": ACTION_NONE}
					_reserve(nid, job)
					it = inventory.get_item(nid)
				var at := _item_pos(it)
				var goals := _reach_positions(at, -1)
				job._fetch_tile = at
				if goals.is_empty():
					_set_item_unreachable(it.id, _tick)
					_release_item(job)
					return {"action": ACTION_WAIT}
				if not goals.has(npc.tile):
					return {"action": ACTION_GOTO, "goals": goals}
				var want := minf(need - _site(job), Inventory.CARRY_CAPACITY_KG)
				var r: CommandResult
				if it.holder == Inventory.Holder.CRATE:
					r = inventory.take_from_crate(it.id, npc.id, want)
				else:
					r = inventory.pick_up(it.id, npc.id, want)
				_release_item(job)
				if not r.ok:
					return {"action": ACTION_WAIT}
				job.carried_id = r.data["item_id"]
				job.phase = Job.PHASE_DELIVER
			Job.PHASE_DELIVER:
				var carried := inventory.carried_by(npc.id)
				if carried == null or carried.id != job.carried_id:
					job.carried_id = ""
					job.phase = Job.PHASE_FETCH
					continue
				var goals := _work_goals(job)
				if goals.is_empty():
					_give_up(job, REASON_UNREACHABLE)
					return {"action": ACTION_NONE}
				if not goals.has(npc.tile):
					return {"action": ACTION_GOTO, "goals": goals}
				var r := inventory.deliver_to_site(npc.id, job.id)
				if r.ok:
					_site_kg[job.id] = float(r.data["site_kg"])
				job.carried_id = ""
				job.phase = Job.PHASE_WORK if _site(job) + KG_EPSILON >= need else Job.PHASE_FETCH
			Job.PHASE_WORK:
				if _site(job) + KG_EPSILON < need:
					job.phase = Job.PHASE_FETCH
					continue
				var goals := _work_goals(job)
				if goals.is_empty():
					_give_up(job, REASON_UNREACHABLE)
					return {"action": ACTION_NONE}
				if not goals.has(npc.tile):
					return {"action": ACTION_GOTO, "goals": goals}
				var block_tiles := _blocking_tiles(job)
				if not block_tiles.is_empty():
					var blocker: Npc = null
					if _colony != null:
						for bt in block_tiles:
							blocker = _colony.npc_at(bt)
							if blocker != null:
								break
					if blocker != null:
						job.wait_reason = REASON_BLOCKED
						job._blocked_ticks += 1
						if job._blocked_ticks >= STEP_ASIDE_AFTER_TICKS and blocker != npc \
								and not blocker.is_moving() and blocker.command_target == NO_TILE:
							job._blocked_ticks = 0
							var lo := block_tiles[0]
							var hi := block_tiles[0]
							for bt in block_tiles:
								lo = Vector2i(mini(lo.x, bt.x), mini(lo.y, bt.y))
								hi = Vector2i(maxi(hi.x, bt.x), maxi(hi.y, bt.y))
							_colony.step_aside(blocker, Rect2i(lo, hi - lo + Vector2i.ONE))
						return {"action": ACTION_WAIT}
					job._blocked_ticks = 0
				if job.order_kind == DesignationMap.Kind.BUILD_WALL:
					# A wall would bury ground stacks: carry them off the site first.
					var junk := _ground_items_at(job.tile)
					if not junk.is_empty():
						var picked := _take_off_site(junk, npc)
						if picked.is_empty():
							job.wait_reason = REASON_ITEMS_IN_WAY  # being fetched by someone else
							return {"action": ACTION_WAIT}
						job.carried_id = picked
						job.wait_reason = ""
						job.phase = Job.PHASE_CLEAR
						continue
				job.wait_reason = ""
				job.work_ticks += 1
				var total := maxi(1, int(rec["work_ticks"]))
				npc.work_progress = minf(1.0, float(job.work_ticks) / total)
				if job.work_ticks >= total:
					_complete_build(job)
					return {"action": ACTION_NONE}
				return {"action": ACTION_WORK}
			Job.PHASE_CLEAR:
				var carried := inventory.carried_by(npc.id)
				if carried == null or carried.id != job.carried_id:
					job.carried_id = ""
					job.phase = Job.PHASE_WORK
					continue
				var spots := _clear_spots(job.tile)
				if spots.is_empty() or spots.has(npc.tile):
					_put_down(npc.id, npc.tile)  # npc.tile is never the wall tile
					job.carried_id = ""
					job.phase = Job.PHASE_WORK
					continue
				return {"action": ACTION_GOTO, "goals": spots}
			_:
				job.phase = Job.PHASE_FETCH
	return {"action": ACTION_WAIT}


## Picks up one stack lying on a wall site (npc stands in reach). Stacks a
## working NPC is fetching are left alone; an unstarted haul job gives its
## stack up. Returns the carried item id, or "".
func _take_off_site(stacks: Array[ItemStack], npc: Npc) -> String:
	for it in stacks:
		var owner_id: String = _item_res.get(it.id, "")
		if not owner_id.is_empty():
			var oj: Job = _jobs.get(owner_id)
			if oj != null and not oj.worker_id.is_empty():
				continue
			if oj != null:
				if oj.kind == Job.KIND_HAUL:
					_delete_job(oj)
				else:
					_release_item(oj)
			_item_res.erase(it.id)
		var r := inventory.pick_up(it.id, npc.id, Inventory.CARRY_CAPACITY_KG)
		if r.ok:
			return r.data["item_id"]
	return ""


## Standable spots with a solid floor near a wall site where a cleared stack
## can be put down: not the site, not on any wall order.
func _clear_spots(site: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for dy in range(-CLEAR_RADIUS, CLEAR_RADIUS + 1):
		for dx in range(-CLEAR_RADIUS, CLEAR_RADIUS + 1):
			if absi(dx) + absi(dy) > CLEAR_RADIUS or (dx == 0 and dy == 0):
				continue
			var p := site + Vector2i(dx, dy)
			if not grid.is_solid_at(p + Vector2i.DOWN) or not nav.can_stand(p):
				continue
			if designations.get_kind(p) == DesignationMap.Kind.BUILD_WALL:
				continue
			out.append(p)
	return out


## Ground stacks on one tile, via the chunk index (no full item scan).
func _ground_items_at(tile: Vector2i) -> Array[ItemStack]:
	var out: Array[ItemStack] = []
	var b: Variant = _ground_by_chunk.get(_chunk_of(tile))
	if b == null:
		return out
	for iid: String in b:
		var it := inventory.get_item(iid)
		if it != null and it.holder == Inventory.Holder.GROUND and it.tile == tile:
			out.append(it)
	return out


## True if an NPC with feet at f would have a wall order tile in its body.
func body_on_wall_order(f: Vector2i) -> bool:
	if _wall_orders <= 0:
		return false
	for k in nav.clearance:
		var p := f + Vector2i(0, -k)
		if grid.in_bounds(p) and designations.get_kind(p) == DesignationMap.Kind.BUILD_WALL:
			return true
	return false


func _drive_haul(job: Job, npc: Npc) -> Dictionary:
	for _step in 3:
		match job.phase:
			Job.PHASE_FETCH, Job.PHASE_OPEN:
				job.phase = Job.PHASE_FETCH
				if not job.carried_id.is_empty():
					job.phase = Job.PHASE_DELIVER
					continue
				var it := _reserved_ground_item(job)
				if it == null:
					_unassign(job)
					return {"action": ACTION_NONE}
				var goals := _reach_positions(it.tile, -1)
				job._fetch_tile = it.tile
				if goals.is_empty():
					_set_item_unreachable(it.id, _tick)
					_unassign(job)
					return {"action": ACTION_NONE}
				if not goals.has(npc.tile):
					return {"action": ACTION_GOTO, "goals": goals}
				var r := inventory.pick_up(it.id, npc.id, Inventory.CARRY_CAPACITY_KG)
				if not r.ok:
					_unassign(job)
					return {"action": ACTION_NONE}
				_release_item(job)
				job.carried_id = r.data["item_id"]
				var picked := inventory.get_item(job.carried_id)
				var bc := _booked_crate(job)
				var bt := stockpiles.booked_tile(job.id)
				if not bc.is_empty():
					crates.book(bc, picked.kg, job.id)  # resize; keeps old booking on failure
				elif bt != NO_TILE:
					stockpiles.book(bt, picked.kg, job.id)
				job.phase = Job.PHASE_DELIVER
			Job.PHASE_DELIVER:
				var carried := inventory.carried_by(npc.id)
				if carried == null or carried.id != job.carried_id:
					job.carried_id = ""
					_unassign(job)
					return {"action": ACTION_NONE}
				var bc := _booked_crate(job)
				if not bc.is_empty() and not crates.accepts(bc, carried.material):
					crates.release(job.id)  # filter changed on the way (M3-QA-3): re-book below
				var t := _haul_target(job)
				if t == NO_TILE:
					# Booking lost (crate removed, zone gone): crate first, then a zone tile.
					if not _book_storage(job, carried.material, carried.kg, npc.tile, npc):
						_finish_haul_here(job, npc)
						return {"action": ACTION_NONE}
					t = _haul_target(job)
				var goals := _reach_positions(t, -1)
				if goals.is_empty():
					_release_storage(job)
					_finish_haul_here(job, npc)
					return {"action": ACTION_NONE}
				if not goals.has(npc.tile):
					return {"action": ACTION_GOTO, "goals": goals}
				var crate_id := _booked_crate(job)
				if not crate_id.is_empty():
					inventory.store_in_crate(npc.id, crate_id)
					crates.release(job.id)
				else:
					_put_down(npc.id, t)
				job.carried_id = ""
				_remove_finished(job)
				return {"action": ACTION_NONE}
			_:
				job.phase = Job.PHASE_FETCH
	return {"action": ACTION_WAIT}


## No stockpile space any more: drop the stack where the NPC stands.
func _finish_haul_here(job: Job, npc: Npc) -> void:
	_put_down(npc.id, npc.tile)
	job.carried_id = ""
	_remove_finished(job)


func _complete_dig(job: Job) -> void:
	var def := grid.registry.get_def(grid.get_tile(job.tile))
	job.phase = Job.PHASE_DONE  # our designations_changed handler ignores it now
	var r := grid.apply_edit(Rect2i(job.tile, Vector2i.ONE), WorldGrid.Edit.DIG)
	if r.ok and def != null and def.drop_kg > 0.0:
		inventory.spawn_ground(def.key, def.drop_kg, _landing(job.tile))
	_remove_finished(job)


func _complete_build(job: Job) -> void:
	if job.kind == Job.KIND_BUILDING:
		_complete_building(job)
		return
	var wall := job.order_kind == DesignationMap.Kind.BUILD_WALL
	var ok := grid.can_place_structure(job.tile, WorldGrid.Structure.LADDER)
	if wall:
		ok = grid.can_build(grid.get_tile(job.tile)) \
				and grid.get_structure(job.tile) == WorldGrid.Structure.NONE
	if not ok:
		_cancel(job)
		return
	var mats := {}
	for it in inventory.site_items(job.id):
		mats[it.material] = float(mats.get(it.material, 0.0)) + it.kg
	job.phase = Job.PHASE_DONE
	inventory.consume_site(job.id)
	_site_kg.erase(job.id)
	if wall:
		grid.apply_edit(Rect2i(job.tile, Vector2i.ONE), WorldGrid.Edit.BUILD_WALL)
	elif grid.apply_structure(job.tile, WorldGrid.Structure.LADDER).ok:
		_ladder_mats[_idx(job.tile)] = mats  # refunded on deconstruct (M3-QA-1)
	_remove_finished(job)


# --- Assignment helpers -------------------------------------------------

## Best open jobs for npc: highest priority, then nearest. Scans chunk rings
## around the NPC and stops once no unseen job can beat the K-th best; a
## confined NPC only looks at chunks around its known region.
func _top_candidates(npc: Npc, tick: int) -> Array[Job]:
	var best: Array[Job] = []
	var scores: Array[int] = []
	var zone_ok := _has_usable_zone(npc)
	if npc._region_valid:
		for c in grid.chunks_in_rect(npc._region_bbox.grow(nav.clearance + 1)):
			_scan_bucket(grid.chunk_index(c), npc, tick, best, scores, true, zone_ok)
		return best
	var p_max := -1
	for p in range(_prio_count.size() - 1, -1, -1):
		if _prio_count[p] > 0:
			p_max = p
			break
	if p_max < 0:
		return best
	var c0 := npc.tile / WorldGrid.CHUNK_SIZE
	var cy_n := grid.chunks_y()
	var max_r := maxi(_chunks_x, cy_n)
	for r in max_r + 1:
		for dy in range(-r, r + 1):
			var cy := c0.y + dy
			if cy < 0 or cy >= cy_n:
				continue
			var edge := dy == -r or dy == r
			var dx := -r
			while dx <= r:
				var cx := c0.x + dx
				if cx >= 0 and cx < _chunks_x:
					_scan_bucket(cy * _chunks_x + cx, npc, tick, best, scores, false, zone_ok)
				dx += 1 if edge or r == 0 else 2 * r
		if best.size() >= ASSIGN_CANDIDATES:
			var kth := best[ASSIGN_CANDIDATES - 1]
			var kth_d := kth.priority * 1000000 - scores[ASSIGN_CANDIDATES - 1]
			if kth.priority >= p_max and kth_d <= r * WorldGrid.CHUNK_SIZE:
				break
	return best


## Could npc deliver to zone tile t? (Not a tile it already failed to reach,
## and inside its known region if it is confined.)
func _drop_ok_for(t: Vector2i, npc: Npc) -> bool:
	var i := _idx(t)
	if npc._blocked_drops.has(i):
		return false
	return not npc._region_valid or npc._region_reach.has(i)


## Any crate or zone tile npc could deliver to (capacity not checked).
func _has_usable_zone(npc: Npc) -> bool:
	if npc._blocked_drops.is_empty() and not npc._region_valid:
		return stockpiles.count() > 0 or not _crates_cached().is_empty()
	for e: Dictionary in _crates_cached():
		if _drop_ok_for(e["tile"], npc):
			return true
	for t in stockpiles.tiles():
		if _drop_ok_for(t, npc):
			return true
	return false


## QA-8: moves a haul job's booking to the nearest crate (preferred, D-021)
## or zone tile that npc can deliver to and that has room. False if none.
## Each failed delivery blocks one more tile for that NPC (or records its
## confined region), so re-booking cannot loop forever.
func _rebook_for(job: Job, it: ItemStack, npc: Npc) -> bool:
	var kg := minf(it.kg, Inventory.CARRY_CAPACITY_KG)
	return _book_storage(job, it.material, kg, it.tile, npc, _haul_target(job))


## Books storage for a haul job: the nearest accepting crate with room,
## else the nearest zone tile with room (Manhattan from near). With npc, only
## targets that NPC can deliver to; `skip` (a tile) is never chosen. The
## job's other booking kind is released. False if nothing fits.
func _book_storage(job: Job, material: StringName, kg: float, near: Vector2i, npc: Npc,
		skip: Vector2i = NO_TILE) -> bool:
	if crates != null:
		var best := ""
		var best_d := 0
		for e: Dictionary in _crates_cached():
			var ct: Vector2i = e["tile"]
			var d := absi(ct.x - near.x) + absi(ct.y - near.y)
			if (not best.is_empty() and d >= best_d) or ct == skip:
				continue
			if (npc != null and not _drop_ok_for(ct, npc)) or not _crate_accepts(e, material) \
					or _crate_free(e) + KG_EPSILON < kg:
				continue
			best = e["id"]
			best_d = d
		if not best.is_empty() and crates.book(best, kg, job.id).ok:
			stockpiles.release(job.id)
			return true
	var cands: Array = []
	for t in stockpiles.tiles():
		if t != skip and (npc == null or _drop_ok_for(t, npc)):
			cands.append([absi(t.x - near.x) + absi(t.y - near.y), t])
	cands.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	for c: Array in cands:
		if stockpiles.free_capacity(c[1]) + KG_EPSILON >= kg and stockpiles.book(c[1], kg, job.id).ok:
			if crates != null:
				crates.release(job.id)
			return true
	return false


func _scan_bucket(ci: int, npc: Npc, tick: int, best: Array[Job], scores: Array[int],
		region_only: bool, zone_ok: bool) -> void:
	var bucket: Variant = _open_chunks.get(ci)
	if bucket == null:
		return
	for job: Job in (bucket as Dictionary).values():
		if not npc.work_enabled.get(job.work_type(), false) or npc.is_ignoring(job.id, tick):
			continue
		if int(job._marks.get(npc.id, -1)) > tick:
			continue
		if region_only and not npc._region_reach.has(_idx(job.tile)):
			continue
		if job.kind == Job.KIND_HAUL and not zone_ok:
			var bt := _haul_target(job)
			if bt == NO_TILE or not _drop_ok_for(bt, npc):
				continue  # no zone tile this NPC could deliver to at all
		var score := job.priority * 1000000 \
				- (absi(job.tile.x - npc.tile.x) + absi(job.tile.y - npc.tile.y))
		var n := best.size()
		if n >= ASSIGN_CANDIDATES and score <= scores[n - 1]:
			continue
		var i := n
		while i > 0 and scores[i - 1] < score:
			i -= 1
		scores.insert(i, score)
		best.insert(i, job)
		if best.size() > ASSIGN_CANDIDATES:
			scores.pop_back()
			best.pop_back()


## Goals of the first walk of a job for npc: {"goals", "item_id"?} or
## {"reason"}: REASON_UNREACHABLE (no work position for anyone),
## REASON_NO_MATERIAL, or another text (not possible for this NPC only).
func _first_goals(job: Job, npc: Npc) -> Dictionary:
	var goals: Array[Vector2i] = []
	var item_id := ""
	match job.kind:
		Job.KIND_DIG, Job.KIND_DECONSTRUCT:
			goals = _work_goals(job)
		Job.KIND_BUILD, Job.KIND_BUILDING:
			var work := _work_goals(job)
			if work.is_empty():
				return {"reason": REASON_UNREACHABLE}
			if npc._region_valid and not _any_in_region(work, npc):
				return {"reason": "site out of reach"}
			var rec := _recipe(job)
			if rec.is_empty():
				return {"reason": "unknown building"}
			var need := float(rec["kg"])
			if _site(job) + KG_EPSILON >= need:
				goals = work
			else:
				item_id = _find_material(job, npc)
				if item_id.is_empty():
					# M3-QA-4: "no material" only when none exists anywhere; a
					# confined NPC whose material lies outside its region has a
					# reach problem (marked for that NPC only).
					if npc._region_valid and not _find_material(job, npc, false).is_empty():
						return {"reason": "material out of reach"}
					return {"reason": REASON_NO_MATERIAL}
				goals = _reach_positions(_item_pos(inventory.get_item(item_id)), -1)
				if goals.is_empty():
					_set_item_unreachable(item_id, _tick)
					return {"reason": "material unreachable"}
		Job.KIND_HAUL:
			var it := _reserved_ground_item(job)
			if it == null:
				return {"reason": "item gone"}
			var bt := _haul_target(job)
			if bt == NO_TILE or not _drop_ok_for(bt, npc):
				# QA-8: the booked tile is out of this NPC's reach (or the
				# booking is gone): move the booking to a zone tile it can use.
				if not _rebook_for(job, it, npc):
					return {"reason": "stockpile out of reach"}
			goals = _reach_positions(it.tile, -1)
			if goals.is_empty():
				_set_item_unreachable(it.id, _tick)
				return {"reason": "item unreachable"}
	if goals.is_empty():
		return {"reason": REASON_UNREACHABLE}
	return {"goals": goals, "item_id": item_id}


func _assign(job: Job, npc: Npc, item_id: String) -> void:
	job.worker_id = npc.id
	npc.job_id = job.id
	job.wait_reason = ""
	match job.kind:
		Job.KIND_DIG, Job.KIND_DECONSTRUCT:
			job.phase = Job.PHASE_WORK
		Job.KIND_BUILD, Job.KIND_BUILDING:
			if not item_id.is_empty():
				_reserve(item_id, job)
				job.phase = Job.PHASE_FETCH
			else:
				job.phase = Job.PHASE_WORK
		Job.KIND_HAUL:
			job.phase = Job.PHASE_FETCH
	if not job.item_id.is_empty():
		job._fetch_tile = _item_pos(inventory.get_item(job.item_id))
	_refresh_open(job)
	jobs_changed.emit()


## Worker gives up (reason shown in the inspector); dig/build orders stay.
func _give_up(job: Job, reason: String) -> void:
	_unassign(job)
	if not _jobs.has(job.id):
		return
	if reason == REASON_UNREACHABLE:
		_set_job_unreachable(job, _tick, true)
	else:
		job.wait_reason = reason


## Nearest unreserved accepted ground item (Manhattan from the NPC). Items
## held by a haul job nobody works on yet may be taken over. A confined NPC
## only considers items inside its reach.
func _find_material(job: Job, npc: Npc, in_region: bool = true) -> String:
	var mats: Array = _recipe(job).get("materials", [])
	var near := npc.tile
	var best := ""
	var best_d := 0
	# Stacks in crates (M3): taken out with take_from_crate.
	for e: Dictionary in _crates_cached():
		var ct: Vector2i = e["tile"]
		var d := absi(ct.x - near.x) + absi(ct.y - near.y)
		if not best.is_empty() and d >= best_d:
			continue
		if in_region and npc._region_valid and not npc._region_reach.has(_idx(ct)):
			continue
		var held: Variant = _crate_items_idx.get(e["id"])
		if held == null:
			continue
		for iid: String in held:
			var it := inventory.get_item(iid)
			if it == null or not (it.material in mats) or _item_res.has(iid) \
					or int(_item_unreachable.get(iid, -1)) > _tick:
				continue
			best = iid
			best_d = d
			break
	# Rings of chunks around the NPC (ground chunk index); stop once no unseen
	# chunk can hold a nearer stack.
	var c0 := Vector2i(clampi(near.x, 0, grid.width - 1), clampi(near.y, 0, grid.height - 1)) \
			/ WorldGrid.CHUNK_SIZE
	var cy_n := grid.chunks_y()
	for r in maxi(_chunks_x, cy_n) + 1:
		for dy in range(-r, r + 1):
			var cy := c0.y + dy
			if cy < 0 or cy >= cy_n:
				continue
			var edge := dy == -r or dy == r
			var dx := -r
			while dx <= r:
				var cx := c0.x + dx
				dx += 1 if edge or r == 0 else 2 * r
				if cx < 0 or cx >= _chunks_x:
					continue
				var b: Variant = _ground_by_chunk.get(cy * _chunks_x + cx)
				if b == null:
					continue
				for iid: String in b:
					var it := inventory.get_item(iid)
					if it == null or it.holder != Inventory.Holder.GROUND or not (it.material in mats):
						continue
					var d := absi(it.tile.x - near.x) + absi(it.tile.y - near.y)
					if not best.is_empty() and d >= best_d:
						continue
					if int(_item_unreachable.get(iid, -1)) > _tick:
						continue
					if in_region and npc._region_valid and not npc._region_reach.has(_idx(it.tile)):
						continue
					var owner_id: String = _item_res.get(iid, "")
					if not owner_id.is_empty():
						var oj: Job = _jobs.get(owner_id)
						if oj == null or oj.kind != Job.KIND_HAUL or not oj.worker_id.is_empty():
							continue
					best = iid
					best_d = d
		if not best.is_empty() and best_d <= r * WorldGrid.CHUNK_SIZE:
			break
	return best


func _reserve(item_id: String, job: Job) -> void:
	var owner_id: String = _item_res.get(item_id, "")
	if not owner_id.is_empty() and owner_id != job.id:
		var oj: Job = _jobs.get(owner_id)
		if oj != null:
			_delete_job(oj)  # an unstarted haul job gives the stack up
		_item_res.erase(item_id)
	_release_item(job)
	_item_res[item_id] = job.id
	job.item_id = item_id


func _release_item(job: Job) -> void:
	if job.item_id.is_empty():
		return
	if _item_res.get(job.item_id, "") == job.id:
		_item_res.erase(job.item_id)
	var iid := job.item_id
	job.item_id = ""
	_queue_item(iid)


func _reserved_ground_item(job: Job) -> ItemStack:
	if job.item_id.is_empty() or _item_res.get(job.item_id, "") != job.id:
		return null
	var it := inventory.get_item(job.item_id)
	if it == null or it.holder != Inventory.Holder.GROUND:
		return null
	return it


## Reserved material on the ground or in a crate (build / building jobs).
func _reserved_item(job: Job) -> ItemStack:
	if job.item_id.is_empty() or _item_res.get(job.item_id, "") != job.id:
		return null
	var it := inventory.get_item(job.item_id)
	if it == null or not (it.holder == Inventory.Holder.GROUND or it.holder == Inventory.Holder.CRATE):
		return null
	return it


# --- M3: buildings, deconstruction, crates ------------------------------

## {"materials", "kg", "work_ticks"} for a material-needing job; {} if unknown.
func _recipe(job: Job) -> Dictionary:
	if job.kind == Job.KIND_BUILDING:
		var d: BuildingDef = buildings.def(job.building_key) if buildings != null else null
		if d == null:
			return {}
		var mats: Array[StringName] = []
		mats.assign(d.materials)
		return {"materials": mats, "kg": d.kg, "work_ticks": d.work_ticks}
	return ConstructionDefs.recipe(job.order_kind)


## Footprint of a building / building-order job (empty rect for tile jobs).
func _job_rect(job: Job) -> Rect2i:
	if buildings == null:
		return Rect2i()
	if job.kind == Job.KIND_BUILDING:
		return buildings.footprint(job.building_key, job.tile)
	if job.kind == Job.KIND_DECONSTRUCT and not job.order_id.is_empty():
		var b := buildings.get_building(job.order_id)
		if not b.is_empty():
			return buildings.footprint(b["key"], b["origin"])
	return Rect2i()


## Tiles that must be free of NPC bodies when the work completes: a wall
## tile, or a door's footprint.
func _blocking_tiles(job: Job) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if job.kind == Job.KIND_BUILD and job.order_kind == DesignationMap.Kind.BUILD_WALL:
		out.append(job.tile)
	elif job.kind == Job.KIND_BUILDING and buildings != null:
		var d := buildings.def(job.building_key)
		if d != null and d.is_door:
			var r := _job_rect(job)
			for y in range(r.position.y, r.end.y):
				for x in range(r.position.x, r.end.x):
					out.append(Vector2i(x, y))
	return out


## Where an item is reached from: its ground tile, or its crate's tile.
func _item_pos(it: ItemStack) -> Vector2i:
	if it == null:
		return NO_TILE
	if it.holder == Inventory.Holder.GROUND:
		return it.tile
	if it.holder == Inventory.Holder.CRATE:
		return _crate_tile(it.holder_id)
	return NO_TILE


func _crate_tile(crate_id: String) -> Vector2i:
	if buildings == null:
		return NO_TILE
	var b := buildings.get_building(crate_id)
	return b["origin"] if not b.is_empty() else NO_TILE


func _booked_crate(job: Job) -> String:
	return crates.booked_crate(job.id) if crates != null else ""


## Tile a haul job delivers to: its booked crate, else its booked zone tile.
func _haul_target(job: Job) -> Vector2i:
	var cid := _booked_crate(job)
	if not cid.is_empty():
		return _crate_tile(cid)
	return stockpiles.booked_tile(job.id)


func _release_storage(job: Job) -> void:
	stockpiles.release(job.id)
	if crates != null:
		crates.release(job.id)


## Spawns building materials (material -> kg) on the ground at the first
## supported tile at/below `tile` (100 % refund, D-021).
func _drop_materials(mats: Dictionary, tile: Vector2i) -> void:
	var land := _landing(tile)
	var keys := mats.keys()
	keys.sort_custom(func(a: Variant, b: Variant) -> bool: return String(a) < String(b))
	for m: Variant in keys:
		var kg := float(mats[m])
		if kg > 0.0:
			inventory.spawn_ground(StringName(str(m)), kg, land)


func _complete_building(job: Job) -> void:
	if buildings == null or not buildings.can_place(job.building_key, job.tile).ok:
		if build_orders != null:
			build_orders.remove(job.order_id)  # order cannot be completed any more
		_cancel(job)
		return
	var mats := {}
	for it in inventory.site_items(job.id):
		mats[it.material] = float(mats.get(it.material, 0.0)) + it.kg
	job.phase = Job.PHASE_DONE  # our orders_changed handler ignores it now
	if build_orders != null:
		build_orders.remove(job.order_id)
	inventory.consume_site(job.id)
	_site_kg.erase(job.id)
	buildings.place(job.building_key, job.tile, mats)
	_remove_finished(job)


## Deconstruct work: the same ticks as building it (PLACEHOLDER).
func _deconstruct_ticks(job: Job) -> int:
	if not job.order_id.is_empty() and buildings != null:
		var b := buildings.get_building(job.order_id)
		var d: BuildingDef = buildings.def(b.get("key", &"")) if not b.is_empty() else null
		return maxi(1, d.work_ticks if d != null else 1)
	var kind := ConstructionDefs.KIND_BUILD_WALL if grid.get_tile(job.tile) == TileRegistry.CONCRETE \
			else ConstructionDefs.KIND_BUILD_LADDER
	return maxi(1, int(ConstructionDefs.recipe(kind).get("work_ticks", 1)))


func _drive_deconstruct(job: Job, npc: Npc) -> Dictionary:
	var goals := _work_goals(job)
	if goals.is_empty():
		_give_up(job, REASON_UNREACHABLE)
		return {"action": ACTION_NONE}
	if not goals.has(npc.tile):
		return {"action": ACTION_GOTO, "goals": goals}
	job.phase = Job.PHASE_WORK
	job.work_ticks += 1
	var total := _deconstruct_ticks(job)
	npc.work_progress = minf(1.0, float(job.work_ticks) / total)
	if job.work_ticks >= total:
		_complete_deconstruct(job)
		return {"action": ACTION_NONE}
	return {"action": ACTION_WORK}


## Wall -> air + the wall recipe's rock; ladder -> removed + the ladder
## recipe's kg (dirt: the material actually used is not tracked); building ->
## crate contents to the ground, then removed with its materials refunded.
func _complete_deconstruct(job: Job) -> void:
	job.phase = Job.PHASE_DONE  # our designations_changed handler ignores it now
	if not job.order_id.is_empty():
		var b: Dictionary = buildings.get_building(job.order_id) if buildings != null else {}
		if not b.is_empty():
			var land := _landing(b["origin"])
			if crates != null and crates.is_crate(job.order_id):
				inventory.empty_crate_to_ground(job.order_id, land)
			var r := buildings.remove(job.order_id)
			if r.ok:
				_drop_materials(r.data["materials"], b["origin"])
	elif grid.get_tile(job.tile) == TileRegistry.CONCRETE:
		if grid.apply_edit(Rect2i(job.tile, Vector2i.ONE), WorldGrid.Edit.DECONSTRUCT_WALL).ok:
			var rec := ConstructionDefs.recipe(ConstructionDefs.KIND_BUILD_WALL)
			_drop_materials({rec["materials"][0]: rec["kg"]}, job.tile)
	elif grid.is_ladder(job.tile):
		var mats: Dictionary = _ladder_mats.get(_idx(job.tile), {})
		if mats.is_empty():  # built before materials were tracked (old save, dev tool)
			var rec := ConstructionDefs.recipe(ConstructionDefs.KIND_BUILD_LADDER)
			mats = {LADDER_REFUND_MATERIAL: rec["kg"]}
		_ladder_mats.erase(_idx(job.tile))
		if grid.remove_structure(job.tile).ok:
			_drop_materials(mats, job.tile)
	_remove_finished(job)


## A building lost its support (Buildings removed it): its materials and any
## crate contents drop to the ground; jobs on it were already cancelled or
## re-route through the normal signals.
func _on_building_lost(id: String, _key: StringName, origin: Vector2i, materials: Dictionary) -> void:
	var land := _landing(origin)
	if not inventory.crate_items(id).is_empty():
		inventory.empty_crate_to_ground(id, land)
	_drop_materials(materials, origin)
	var dj: Job = _jobs.get(_decon_by_building.get(id, ""))
	if dj != null and not dj.is_done():
		_cancel(dj)


func _on_crates_changed(_building_id: String) -> void:
	_crate_list_valid = false
	# A new crate (or a filter change) may take items that had no place.
	for iid: String in _haul_retry:
		_queue_item(iid)
	_haul_retry.clear()


func _on_orders_changed(_rect: Rect2i) -> void:
	if _sync_orders():
		jobs_changed.emit()


## One building job per BuildOrders order. True if anything changed.
func _sync_orders() -> bool:
	if build_orders == null:
		return false
	var changed := false
	var live := {}
	for o in build_orders.orders():
		var oid: String = o["id"]
		live[oid] = true
		var job: Job = _jobs.get(_by_order.get(oid, ""))
		if job == null:
			job = Job.new()
			job.id = ids.allocate(ID_CATEGORY)
			job.kind = Job.KIND_BUILDING
			job.order_kind = DesignationMap.Kind.NONE
			job.order_id = oid
			job.building_key = o["key"]
			job.tile = o["origin"]
			job.priority = o["priority"]
			_jobs[job.id] = job
			_by_order[oid] = job.id
			_refresh_open(job)
			changed = true
		elif job.priority != int(o["priority"]):
			job.priority = o["priority"]
			_refresh_open(job)
			changed = true
	for oid: String in _by_order.keys():
		if live.has(oid):
			continue
		var job: Job = _jobs.get(_by_order[oid])
		if job == null:
			_by_order.erase(oid)
		elif not job.is_done():
			_cancel(job)
			changed = true
	return changed


func _site(job: Job) -> float:
	return float(_site_kg.get(job.id, 0.0))


# --- Unreachable marks and regions --------------------------------------

## This NPC found no path to job: it skips the job for a while. If every
## eligible NPC is now blocked, the job itself becomes unreachable.
func _mark(job: Job, npc: Npc, tick: int) -> void:
	if not _jobs.has(job.id):
		return
	job._marks[npc.id] = tick + UNREACHABLE_RETRY_TICKS
	_add_marked(job)
	# The job-level flag ("nobody can reach it") is set by _sweep_unreachable:
	# checking all NPCs here for every failed candidate was too slow (QA-2).


func _all_blocked(job: Job, tick: int) -> bool:
	var colony := _colony
	if colony == null:
		return false
	var eligible := 0
	for npc in colony.all_npcs():
		if not npc.work_enabled.get(job.work_type(), false):
			continue
		eligible += 1
		if int(job._marks.get(npc.id, -1)) > tick:
			continue
		if npc._region_valid and not _job_in_region(job, npc):
			continue
		return false
	return eligible > 0


func _set_job_unreachable(job: Job, tick: int, geometric: bool = false) -> void:
	if not _jobs.has(job.id):
		return
	job._geo_unreachable = geometric
	job.wait_reason = REASON_UNREACHABLE
	_add_marked(job)
	if geometric:
		# No work position at all: stays flagged until terrain near it changes
		# (_on_tiles_changed -> _clear_unreachable), no periodic re-open.
		job.unreachable_until = GEO_UNREACHABLE
		_refresh_open(job)
		return
	job.unreachable_until = tick + UNREACHABLE_RETRY_TICKS
	if not _reopen_at.has(job.unreachable_until):
		_reopen_at[job.unreachable_until] = []
	(_reopen_at[job.unreachable_until] as Array).append(job.id)
	_refresh_open(job)


func _clear_unreachable(job: Job) -> void:
	job._marks.clear()
	if job.unreachable_until >= 0:
		job.unreachable_until = -1
		if job.wait_reason == REASON_UNREACHABLE:
			job.wait_reason = ""
		_refresh_open(job)


## Confined NPCs skip jobs outside their region without marking them, so a
## few open jobs per tick are checked round-robin: if every eligible NPC is
## blocked, the job is flagged unreachable (overlay) without any search.
func _sweep_unreachable(tick: int) -> void:
	if _jobs.is_empty():
		return
	var n := 0
	while n < SWEEP_PER_TICK:
		if _sweep_i >= _sweep_ids.size():
			_sweep_ids = _jobs.keys()
			_sweep_i = 0
			if n > 0:
				return  # at most one pass per tick
		var job: Job = _jobs.get(_sweep_ids[_sweep_i])
		_sweep_i += 1
		n += 1
		if job != null and job._open and job.kind != Job.KIND_HAUL and _all_blocked(job, tick):
			_set_job_unreachable(job, tick)


func _expire_unreachable(tick: int) -> void:
	var from := _last_update_tick + 1
	_last_update_tick = tick
	var due: Array = []
	if tick - from > 1000:
		for k: int in _reopen_at.keys():
			if k <= tick:
				due.append(k)
	else:
		for k in range(from, tick + 1):
			if _reopen_at.has(k):
				due.append(k)
	for k: int in due:
		for jid: String in _reopen_at[k]:
			var job: Job = _jobs.get(jid)
			if job != null and job.unreachable_until >= 0 and job.unreachable_until <= tick:
				job.unreachable_until = -1
				if job.wait_reason == REASON_UNREACHABLE:
					job.wait_reason = ""
				# Confined NPCs (known regions) still cannot reach it: no search needed.
				if _all_blocked(job, tick):
					_set_job_unreachable(job, tick)
				else:
					_refresh_open(job)
		_reopen_at.erase(k)


func _add_marked(job: Job) -> void:
	var ci := _chunk_of(job.tile)
	if not _marked_chunks.has(ci):
		_marked_chunks[ci] = {}
	(_marked_chunks[ci] as Dictionary)[job.id] = true


func _set_item_unreachable(iid: String, tick: int) -> void:
	if not iid.is_empty():
		_item_unreachable[iid] = tick + UNREACHABLE_RETRY_TICKS


## Records the complete reachable feet tiles of a confined NPC.
func _store_region(npc: Npc, region: PackedInt32Array) -> void:
	npc._region_valid = false
	if region.is_empty() or region.size() > REGION_MAX_TILES:
		return
	var tiles := {}
	var reach := {}
	var lo := Vector2i(grid.width, grid.height)
	var hi := Vector2i(-1, -1)
	var c := nav.clearance
	for idx in region:
		tiles[idx] = true
		var f := _tile_of(idx)
		lo = Vector2i(mini(lo.x, f.x), mini(lo.y, f.y))
		hi = Vector2i(maxi(hi.x, f.x), maxi(hi.y, f.y))
		for ty in range(f.y - c, f.y + 2):
			for tx in range(f.x - 1, f.x + 2):
				if tx >= 0 and ty >= 0 and tx < grid.width and ty < grid.height:
					reach[ty * grid.width + tx] = true
	npc._region = tiles
	npc._region_reach = reach
	npc._region_bbox = Rect2i(lo, hi - lo + Vector2i.ONE)
	npc._region_valid = true
	_region_cache.append({"tiles": tiles, "reach": reach, "bbox": npc._region_bbox})
	if _region_cache.size() > REGION_CACHE_SIZE:
		_region_cache.pop_front()


## An NPC standing inside a recorded region can reach at most that region
## (reachability is directional, so it may be a superset): it adopts it
## instead of searching. A later exhaustive failure records its exact region.
func _adopt_cached_region(npc: Npc) -> void:
	if npc._region_valid or _region_cache.is_empty():
		return
	var idx := _idx(npc.tile)
	for i in range(_region_cache.size() - 1, -1, -1):
		var e: Dictionary = _region_cache[i]
		if (e["tiles"] as Dictionary).has(idx):
			npc._region = e["tiles"]
			npc._region_reach = e["reach"]
			npc._region_bbox = e["bbox"]
			npc._region_valid = true
			return


func _any_in_region(goals: Array[Vector2i], npc: Npc) -> bool:
	for gl in goals:
		if npc._region.has(_idx(gl)):
			return true
	return false


func _job_in_region(job: Job, npc: Npc) -> bool:
	if not npc._region_reach.has(_idx(job.tile)):
		return false
	if job.kind == Job.KIND_HAUL:
		return true
	return _any_in_region(_work_goals(job), npc)


# --- Open-job buckets ---------------------------------------------------

## Keeps job in the open buckets iff it exists, has no worker and is not
## unreachable for everyone.
func _refresh_open(job: Job) -> void:
	var want := _jobs.has(job.id) and not job.is_done() and job.worker_id.is_empty() \
			and job.unreachable_until < 0
	if want == job._open:
		if want and job._open_prio != job.priority:
			_prio_count[job._open_prio] -= 1
			_prio_count[job.priority] += 1
			job._open_prio = job.priority
		return
	var ci := _chunk_of(job.tile)
	if want:
		if not _open_chunks.has(ci):
			_open_chunks[ci] = {}
		(_open_chunks[ci] as Dictionary)[job.id] = job
		job._open_prio = job.priority
		_prio_count[job._open_prio] += 1
	else:
		var b: Variant = _open_chunks.get(ci)
		if b != null:
			(b as Dictionary).erase(job.id)
			if (b as Dictionary).is_empty():
				_open_chunks.erase(ci)
		_prio_count[job._open_prio] -= 1
	job._open = want


func _chunk_of(t: Vector2i) -> int:
	var x := clampi(t.x, 0, grid.width - 1) / WorldGrid.CHUNK_SIZE
	var y := clampi(t.y, 0, grid.height - 1) / WorldGrid.CHUNK_SIZE
	return y * _chunks_x + x


# --- Lifecycle helpers --------------------------------------------------

## Removes the worker from the job: carried material is dropped where the
## NPC stands, the reserved item is released. Haul jobs are deleted (they are
## recreated from the loose item); dig/build jobs go back to open.
func _unassign(job: Job) -> void:
	var w := job.worker_id
	if not w.is_empty():
		var colony := _colony
		var npc: Npc = colony.get_npc(w) if colony != null else null
		if not job.carried_id.is_empty():
			var c := inventory.carried_by(w)
			if c != null and c.id == job.carried_id:
				var drop_tile := npc.tile if npc != null else _landing(job.tile)
				_put_down(w, drop_tile)
			job.carried_id = ""
		job.worker_id = ""
		if npc != null and npc.job_id == job.id:
			colony._on_job_released(npc)
	_release_item(job)
	if job.kind == Job.KIND_HAUL:
		_delete_job(job)
		return
	job.phase = Job.PHASE_OPEN
	_refresh_open(job)
	jobs_changed.emit()


## Order removed / invalid: stop the worker, return site materials, release all.
func _cancel(job: Job) -> void:
	_unassign(job)
	if job.needs_material() and inventory.site_kg(job.id) > 0.0:
		inventory.return_site_to_ground(job.id, _landing(job.tile))
	_site_kg.erase(job.id)
	_delete_job(job)


## Job completed: free the worker and forget the job.
func _remove_finished(job: Job) -> void:
	var w := job.worker_id
	job.worker_id = ""
	var colony := _colony
	if not w.is_empty() and colony != null:
		var npc := colony.get_npc(w)
		if npc != null and npc.job_id == job.id:
			colony._on_job_released(npc)
	_delete_job(job)


func _delete_job(job: Job) -> void:
	if not _jobs.has(job.id):
		return
	_jobs.erase(job.id)
	if job.kind != Job.KIND_HAUL and job.kind != Job.KIND_BUILDING and grid.in_bounds(job.tile) \
			and _by_tile.get(_idx(job.tile), "") == job.id:
		_by_tile.erase(_idx(job.tile))
		_count_wall(job, -1)
	for idx: int in _job_tiles.get(job.id, []):
		if _by_tile.get(idx, "") == job.id:
			_by_tile.erase(idx)
	_job_tiles.erase(job.id)
	if job.kind == Job.KIND_BUILDING and _by_order.get(job.order_id, "") == job.id:
		_by_order.erase(job.order_id)
	if job.kind == Job.KIND_DECONSTRUCT and _decon_by_building.get(job.order_id, "") == job.id:
		_decon_by_building.erase(job.order_id)
	_release_item(job)
	_release_storage(job)
	_site_kg.erase(job.id)
	_refresh_open(job)
	job.phase = Job.PHASE_DONE
	jobs_changed.emit()


func _restore_job(job: Job, carried_claims: Dictionary) -> bool:
	if job.is_done():
		return false
	match job.kind:
		Job.KIND_HAUL:
			job.order_kind = DesignationMap.Kind.NONE
		Job.KIND_BUILDING:
			if build_orders == null or buildings == null:
				return false
			var o := build_orders.get_order(job.order_id)
			if o.is_empty() or _by_order.has(job.order_id):
				return false
			job.order_kind = DesignationMap.Kind.NONE
			job.building_key = o["key"]
			job.tile = o["origin"]
			job.priority = o["priority"]
		Job.KIND_DECONSTRUCT:
			if designations.get_kind(job.tile) != DesignationMap.Kind.DECONSTRUCT \
					or _by_tile.has(_idx(job.tile)):
				return false
			var bid := buildings.building_at(job.tile) if buildings != null else ""
			if bid != job.order_id or (not bid.is_empty() and _decon_by_building.has(bid)):
				return false
			job.order_kind = DesignationMap.Kind.DECONSTRUCT
			job.priority = designations.get_priority(job.tile)
		_:
			var want := designations.get_kind(job.tile)
			var kind_ok := (job.kind == Job.KIND_DIG and job.order_kind == DesignationMap.Kind.DIG) \
					or (job.kind == Job.KIND_BUILD and job.order_kind in
							[DesignationMap.Kind.BUILD_WALL, DesignationMap.Kind.BUILD_LADDER])
			if not kind_ok or want != job.order_kind or _by_tile.has(_idx(job.tile)):
				return false
			job.priority = designations.get_priority(job.tile)
	if not job.item_id.is_empty():
		var it := inventory.get_item(job.item_id)
		var holder_ok := it != null and (it.holder == Inventory.Holder.GROUND
				or (it.holder == Inventory.Holder.CRATE and job.needs_material()))
		if not holder_ok or _item_res.has(job.item_id):
			job.item_id = ""
	if not job.carried_id.is_empty():
		var c := inventory.get_item(job.carried_id)
		if c == null or c.holder != Inventory.Holder.NPC or job.worker_id.is_empty() \
				or c.holder_id != job.worker_id or carried_claims.has(job.carried_id):
			job.carried_id = ""
	if job.kind == Job.KIND_HAUL and job.item_id.is_empty() and job.carried_id.is_empty():
		return false
	if job.worker_id.is_empty():
		job.phase = Job.PHASE_OPEN
	else:
		match job.kind:
			Job.KIND_DIG, Job.KIND_DECONSTRUCT:
				job.phase = Job.PHASE_WORK
			Job.KIND_BUILD, Job.KIND_BUILDING:
				if not job.carried_id.is_empty():
					# A stack cleared off a wall site is never delivered to it.
					job.phase = Job.PHASE_CLEAR if job.phase == Job.PHASE_CLEAR else Job.PHASE_DELIVER
				elif job.phase != Job.PHASE_WORK:
					job.phase = Job.PHASE_FETCH
			Job.KIND_HAUL:
				job.phase = Job.PHASE_DELIVER if not job.carried_id.is_empty() else Job.PHASE_FETCH
	if job.kind == Job.KIND_HAUL and job.worker_id.is_empty() and job.item_id.is_empty():
		return false
	_jobs[job.id] = job
	if not job.carried_id.is_empty():
		carried_claims[job.carried_id] = job.id
	match job.kind:
		Job.KIND_HAUL:
			pass
		Job.KIND_BUILDING:
			_by_order[job.order_id] = job.id
		_:
			_by_tile[_idx(job.tile)] = job.id
			_count_wall(job, 1)
			if job.kind == Job.KIND_DECONSTRUCT and not job.order_id.is_empty():
				_decon_by_building[job.order_id] = job.id
				_job_tiles[job.id] = [_idx(job.tile)]
	if not job.item_id.is_empty():
		_item_res[job.item_id] = job.id
	_refresh_open(job)
	return true


# --- Designations -------------------------------------------------------

func _on_designations_changed(rect: Rect2i) -> void:
	var r := rect.intersection(grid.bounds())
	if not r.has_area():
		return
	var touched := {}
	if r.get_area() <= 4096:
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				touched[y * grid.width + x] = true
	else:
		for idx: int in _by_tile:
			if r.has_point(_tile_of(idx)):
				touched[idx] = true
		for idx: int in designations.entries():
			if r.has_point(_tile_of(idx)):
				touched[idx] = true
	var changed := false
	for idx: int in touched:
		changed = _sync_tile(idx) or changed
	if changed:
		jobs_changed.emit()


func _sync_all_designations() -> void:
	for idx: int in designations.entries():
		_sync_tile(idx)
	for idx: int in _by_tile.keys():
		_sync_tile(idx)


## A tile of a building deconstruct job lost its order: the job keeps the
## other designated tiles (moving its main tile if needed) or is cancelled
## when none is left. True if anything changed.
func _unmap_decon_tile(job: Job, idx: int) -> bool:
	if _by_tile.get(idx, "") == job.id:
		_by_tile.erase(idx)
	var tl: Array = _job_tiles.get(job.id, [])
	tl.erase(idx)
	var left: Array = []
	for i: int in tl:
		if designations.entries().get(i, DesignationMap.Kind.NONE) == DesignationMap.Kind.DECONSTRUCT \
				and _by_tile.get(i, "") == job.id:
			left.append(i)
	if left.is_empty():
		# Unmap every tile still pointing at the job (several may lose their
		# order in the same change, M3-QA-2), then cancel it.
		for i: int in tl:
			if _by_tile.get(i, "") == job.id:
				_by_tile.erase(i)
		_job_tiles.erase(job.id)
		_cancel(job)
		return true
	_job_tiles[job.id] = left
	if _idx(job.tile) == idx:
		var was_open := job._open
		if was_open:
			_set_open_false_for_move(job)
		job.tile = _tile_of(left[0])
		job.priority = designations.get_priority(job.tile)
		_refresh_open(job)
	return true


## The open bucket is keyed by job.tile's chunk: take the job out before
## its tile changes (_refresh_open puts it back).
func _set_open_false_for_move(job: Job) -> void:
	var ci := _chunk_of(job.tile)
	var b: Variant = _open_chunks.get(ci)
	if b != null:
		(b as Dictionary).erase(job.id)
		if (b as Dictionary).is_empty():
			_open_chunks.erase(ci)
	_prio_count[job._open_prio] -= 1
	job._open = false


## Wall orders change where NPCs prefer to stand: cached goals go stale.
func _count_wall(job: Job, delta: int) -> void:
	if job.order_kind == DesignationMap.Kind.BUILD_WALL and job.kind == Job.KIND_BUILD:
		_wall_orders += delta
		_geom_version += 1


## Makes the job on tile index match its order. True if anything changed.
func _sync_tile(idx: int) -> bool:
	var kind: int = designations.entries().get(idx, DesignationMap.Kind.NONE)
	var job: Job = _jobs.get(_by_tile.get(idx, ""))
	if job != null and job.is_done():
		return false
	var tile := _tile_of(idx)
	var bid := ""
	if kind == DesignationMap.Kind.DECONSTRUCT and buildings != null:
		bid = buildings.building_at(tile)
	var changed := false
	if job != null and (job.order_kind != kind or job.order_id != bid):
		if job.kind == Job.KIND_DECONSTRUCT and not job.order_id.is_empty():
			changed = _unmap_decon_tile(job, idx)
		else:
			_cancel(job)
			changed = true
		job = null
	if kind == DesignationMap.Kind.NONE:
		return changed
	if job == null and not bid.is_empty():
		# One deconstruct job per building, shared by all its designated tiles.
		var bj: Job = _jobs.get(_decon_by_building.get(bid, ""))
		if bj != null and not bj.is_done():
			_by_tile[idx] = bj.id
			var tl: Array = _job_tiles.get(bj.id, [])
			if not tl.has(idx):
				tl.append(idx)
			_job_tiles[bj.id] = tl
			return true
	if job == null:
		job = Job.new()
		job.id = ids.allocate(ID_CATEGORY)
		match kind:
			DesignationMap.Kind.DIG:
				job.kind = Job.KIND_DIG
			DesignationMap.Kind.DECONSTRUCT:
				job.kind = Job.KIND_DECONSTRUCT
				job.order_id = bid
			_:
				job.kind = Job.KIND_BUILD
		job.order_kind = kind
		job.tile = tile
		job.priority = designations.get_priority(tile)
		_jobs[job.id] = job
		_by_tile[idx] = job.id
		if not bid.is_empty():
			_decon_by_building[bid] = job.id
			_job_tiles[job.id] = [idx]
		_count_wall(job, 1)
		_refresh_open(job)
		return true
	if job.kind == Job.KIND_DECONSTRUCT and job.tile != tile:
		return changed  # a secondary tile of a building: the job keeps its own tile's priority
	var p := designations.get_priority(tile)
	if job.priority != p:
		job.priority = p
		_refresh_open(job)
		changed = true
	return changed


# --- Hauling -----------------------------------------------------------

func _haul_scan(tick: int) -> void:
	if tick - _last_retry_tick >= HAUL_RETRY_TICKS:
		_last_retry_tick = tick
		for iid: String in _haul_retry:
			_queue_item(iid)
		_haul_retry.clear()
		for iid: String in _item_unreachable.keys():  # prune expired marks
			if int(_item_unreachable[iid]) <= tick:
				_item_unreachable.erase(iid)
	if _haul_queue.is_empty():
		return
	# Free capacity per zone tile, computed once per scan (find_drop_tile
	# semantics: nearest by Manhattan, ties to the first tile in row order).
	var zone_tiles := stockpiles.tiles()
	var free := PackedFloat32Array()
	free.resize(zone_tiles.size())
	if not zone_tiles.is_empty():
		var ground_on := {}
		for iid: String in _ground:
			var gi := inventory.get_item(iid)
			if gi != null and stockpiles.is_stockpile(gi.tile):
				var k := _idx(gi.tile)
				ground_on[k] = float(ground_on.get(k, 0.0)) + gi.kg
		for i in zone_tiles.size():
			var zt := zone_tiles[i]
			free[i] = StockpileZones.TILE_CAPACITY_KG - float(ground_on.get(_idx(zt), 0.0)) \
					- stockpiles.booked_kg(zt)
	var n := 0
	while n < HAUL_SCAN_PER_CADENCE and not _haul_queue.is_empty():
		var iid: String = _haul_queue.pop_front()
		_queued.erase(iid)
		n += 1
		var it := inventory.get_item(iid)
		if it == null or it.holder != Inventory.Holder.GROUND or stockpiles.is_stored(it) \
				or _item_res.has(iid):
			continue
		if int(_item_unreachable.get(iid, -1)) > tick:
			_haul_retry[iid] = true
			continue
		var kg := minf(it.kg, Inventory.CARRY_CAPACITY_KG)
		# Crates first (D-021): nearest accepting crate with room (find_crate
		# semantics, from the crate index: no per-crate inventory scans).
		if crates != null:
			var cid := _nearest_crate_for(it.material, kg, it.tile)
			if not cid.is_empty():
				var cj := _new_haul_job(it)
				if crates.book(cid, kg, cj.id).ok:
					_add_haul_job(cj, iid)
					continue
		var best := -1
		var best_d := 0
		for i in zone_tiles.size():
			if free[i] + KG_EPSILON < kg:
				continue
			var d := absi(zone_tiles[i].x - it.tile.x) + absi(zone_tiles[i].y - it.tile.y)
			if best < 0 or d < best_d:
				best = i
				best_d = d
		if best < 0:
			_haul_retry[iid] = true
			continue
		var job := _new_haul_job(it)
		if not stockpiles.book(zone_tiles[best], kg, job.id).ok:
			_haul_retry[iid] = true
			continue
		free[best] -= kg
		_add_haul_job(job, iid)


## Nearest crate (Manhattan to its origin; ties: smaller y, then x, then id
## order) accepting material with free room >= kg; "" if none.
func _nearest_crate_for(material: StringName, kg: float, near: Vector2i) -> String:
	var best := ""
	var best_d := 0
	var best_o := Vector2i.ZERO
	for e: Dictionary in _crates_cached():
		var o: Vector2i = e["tile"]
		var d := absi(o.x - near.x) + absi(o.y - near.y)
		if not best.is_empty() and (d > best_d or (d == best_d and (o.y > best_o.y
				or (o.y == best_o.y and o.x >= best_o.x)))):
			continue
		if not _crate_accepts(e, material) or _crate_free(e) + KG_EPSILON < kg:
			continue
		best = e["id"]
		best_d = d
		best_o = o
	return best


func _new_haul_job(it: ItemStack) -> Job:
	var job := Job.new()
	job.id = ids.allocate(ID_CATEGORY)
	job.kind = Job.KIND_HAUL
	job.order_kind = DesignationMap.Kind.NONE
	job.tile = it.tile
	job.priority = HAUL_PRIORITY
	return job


func _add_haul_job(job: Job, iid: String) -> void:
	job.item_id = iid
	_jobs[job.id] = job
	_item_res[iid] = job.id
	_refresh_open(job)
	jobs_changed.emit()


func _queue_item(iid: String) -> void:
	if iid.is_empty() or _queued.has(iid) or _item_res.has(iid):
		return
	var it := inventory.get_item(iid)
	if it == null or it.holder != Inventory.Holder.GROUND or stockpiles.is_stored(it):
		return
	_queued[iid] = true
	_haul_queue.append(iid)


func _queue_all_loose() -> void:
	for iid: String in _ground:
		_queue_item(iid)


func _rebuild_ground() -> void:
	_ground.clear()
	_ground_by_chunk.clear()
	for it in inventory.all_items():
		if it.holder == Inventory.Holder.GROUND:
			_ground_set(it)
	_rebuild_crate_index()
	_crate_list_valid = false


## Ground index: item id -> chunk, chunk -> {item id: true}.
func _ground_set(it: ItemStack) -> void:
	var ci := _chunk_of(it.tile)
	var old: Variant = _ground.get(it.id)
	if old != null and int(old) == ci:
		return
	if old != null:
		_ground_unset(it.id)
	_ground[it.id] = ci
	if not _ground_by_chunk.has(ci):
		_ground_by_chunk[ci] = {}
	(_ground_by_chunk[ci] as Dictionary)[it.id] = true


func _ground_unset(iid: String) -> void:
	var old: Variant = _ground.get(iid)
	if old == null:
		return
	_ground.erase(iid)
	var b: Variant = _ground_by_chunk.get(int(old))
	if b != null:
		(b as Dictionary).erase(iid)
		if (b as Dictionary).is_empty():
			_ground_by_chunk.erase(int(old))


func _on_items_changed(item_id: String) -> void:
	if item_id.is_empty():
		_rebuild_ground()
		_queue_all_loose()
		return
	var it := inventory.get_item(item_id)
	if it != null and it.holder == Inventory.Holder.GROUND:
		_ground_set(it)
		_queue_item(item_id)
	else:
		_ground_unset(item_id)
	if it != null and it.holder == Inventory.Holder.CRATE:
		_crate_index_set(it)
	else:
		_crate_index_unset(item_id)


# --- Crate index (M3-QA-6) ------------------------------------------------

func _crate_index_set(it: ItemStack) -> void:
	var old: Variant = _item_crate.get(it.id)
	if old != null and old[0] == it.holder_id and is_equal_approx(float(old[1]), it.kg):
		return
	_crate_index_unset(it.id)
	_item_crate[it.id] = [it.holder_id, it.kg]
	if not _crate_items_idx.has(it.holder_id):
		_crate_items_idx[it.holder_id] = {}
	(_crate_items_idx[it.holder_id] as Dictionary)[it.id] = true
	_crate_kg_idx[it.holder_id] = float(_crate_kg_idx.get(it.holder_id, 0.0)) + it.kg


func _crate_index_unset(iid: String) -> void:
	var old: Variant = _item_crate.get(iid)
	if old == null:
		return
	_item_crate.erase(iid)
	var cid: String = old[0]
	var b: Variant = _crate_items_idx.get(cid)
	if b != null:
		(b as Dictionary).erase(iid)
		if (b as Dictionary).is_empty():
			_crate_items_idx.erase(cid)
	var left := float(_crate_kg_idx.get(cid, 0.0)) - float(old[1])
	if left <= KG_EPSILON:
		_crate_kg_idx.erase(cid)
	else:
		_crate_kg_idx[cid] = left


func _rebuild_crate_index() -> void:
	_item_crate.clear()
	_crate_items_idx.clear()
	_crate_kg_idx.clear()
	for it in inventory.all_items():
		if it.holder == Inventory.Holder.CRATE:
			_crate_index_set(it)


## Crates with origin tile, capacity and filter; rebuilt only after
## crates_changed (crate placed / removed / lost / filter changed).
func _crates_cached() -> Array:
	if _crate_list_valid or crates == null:
		return _crate_list
	_crate_list.clear()
	for cid in crates.crate_ids():
		var b := buildings.get_building(cid)
		var d: BuildingDef = buildings.def(b["key"]) if not b.is_empty() else null
		if d == null:
			continue
		var f: Array = []
		f.assign(crates.get_filter(cid))
		_crate_list.append({"id": cid, "tile": b["origin"], "storage": d.storage_kg, "filter": f})
	_crate_list_valid = true
	return _crate_list


func _crate_free(e: Dictionary) -> float:
	return maxf(0.0, float(e["storage"]) - float(_crate_kg_idx.get(e["id"], 0.0))
			- crates.booked_kg(e["id"]))


static func _crate_accepts(e: Dictionary, material: StringName) -> bool:
	var f: Array = e["filter"]
	return f.is_empty() or f.has(material)


func _on_zones_changed(rect: Rect2i) -> void:
	for iid: String in _haul_retry:
		_queue_item(iid)
	_haul_retry.clear()
	# Items on tiles that stopped being stockpile are loose again.
	for it in _ground_items_in(rect):
		_queue_item(it.id)


## Ground stacks inside rect (chunk index; no full item scan).
func _ground_items_in(rect: Rect2i) -> Array[ItemStack]:
	var out: Array[ItemStack] = []
	for c in grid.chunks_in_rect(rect):
		var b: Variant = _ground_by_chunk.get(grid.chunk_index(c))
		if b == null:
			continue
		for iid: String in (b as Dictionary).keys():
			var it := inventory.get_item(iid)
			if it != null and it.holder == Inventory.Holder.GROUND and rect.has_point(it.tile):
				out.append(it)
	return out


## Item gravity: ground stacks in or above rect whose tile below is no
## longer solid fall to the first tile at/below with a solid tile beneath
## (Inventory.relocate_ground keeps the id, so reservations stay valid and
## the job re-routes via needs_new_route).
func _drop_unsupported_items(rect: Rect2i) -> void:
	var cols := Rect2i(rect.position.x, 0, rect.size.x, rect.end.y).intersection(grid.bounds())
	if not cols.has_area() or _ground.is_empty():
		return
	for it in _ground_items_in(cols):
		if grid.is_solid_at(it.tile + Vector2i.DOWN) and not grid.is_solid_at(it.tile):
			continue
		var land := _landing(it.tile)
		if land != it.tile:
			inventory.relocate_ground(it.id, land)


# --- Geometry ----------------------------------------------------------

func _on_tiles_changed(rect: Rect2i) -> void:
	_geom_version += 1
	_drop_unsupported_items(rect)
	var area := rect.grow(UNREACHABLE_AREA_MARGIN)
	for c in grid.chunks_in_rect(area):
		var ci := grid.chunk_index(c)
		var bucket: Variant = _marked_chunks.get(ci)
		if bucket == null:
			continue
		var d: Dictionary = bucket
		for jid: String in d.keys():
			var job: Job = _jobs.get(jid)
			if job == null:
				d.erase(jid)
			elif area.has_point(job.tile):
				_clear_unreachable(job)
				d.erase(jid)
		if d.is_empty():
			_marked_chunks.erase(ci)
	if not _item_unreachable.is_empty():
		for it in _ground_items_in(area):
			_item_unreachable.erase(it.id)
	var colony := _colony
	if colony != null:
		var m := nav.clearance + NavGrid.MAX_DROP + 2
		for i in range(_region_cache.size() - 1, -1, -1):
			if ((_region_cache[i] as Dictionary)["bbox"] as Rect2i).grow(m).intersects(rect):
				_region_cache.remove_at(i)
		var drop_area := rect.grow(DROP_BLOCK_MARGIN)
		for npc: Npc in colony._npcs.values():
			if npc._region_valid and npc._region_bbox.grow(m).intersects(rect):
				npc._region_valid = false
			if not npc._blocked_drops.is_empty():
				if drop_area.has_point(npc.tile):
					npc._blocked_drops.clear()  # its own surroundings changed: try again
					continue
				for idx: int in npc._blocked_drops.keys():
					if drop_area.has_point(_tile_of(idx)):
						npc._blocked_drops.erase(idx)


## Cached work positions of a dig/build job.
func _work_goals(job: Job) -> Array[Vector2i]:
	if job._goals_version != _geom_version or job._goals_key != job.tile:
		job._goals = _compute_work_goals(job)
		job._goals_version = _geom_version
		job._goals_key = job.tile
	return job._goals


func _compute_work_goals(job: Job) -> Array[Vector2i]:
	match job.kind:
		Job.KIND_BUILDING:
			var d := buildings.def(job.building_key) if buildings != null else null
			return _reach_rect(_job_rect(job), d != null and d.is_door)
		Job.KIND_DECONSTRUCT:
			if not job.order_id.is_empty():
				return _reach_rect(_job_rect(job), false)
			if grid.get_tile(job.tile) == TileRegistry.CONCRETE:
				return _reach_positions(job.tile, DesignationMap.Kind.DIG)  # solid: needs exposure
			return _reach_positions(job.tile, -1)
	return _reach_positions(job.tile, job.order_kind)


## Work positions for a multi-tile footprint: the union of the plain reach of
## its tiles. keep_clear (doors): positions whose body overlaps the footprint
## are left out, so the builder never stands in its own doorway.
func _reach_rect(r: Rect2i, keep_clear: bool) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if not r.has_area():
		return out
	var seen := {}
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			for f in _reach_positions(Vector2i(x, y), -1):
				if seen.has(f):
					continue
				seen[f] = true
				if keep_clear and f.x >= r.position.x and f.x < r.end.x \
						and f.y >= r.position.y and f.y - (nav.clearance - 1) < r.end.y:
					continue
				out.append(f)
	return out


## Standable feet tiles from which tile t is in reach. mode: DesignationMap
## Kind (DIG: t must touch a passable tile; BUILD_WALL: t not in the body),
## anything else = plain reach (ladders, items, drop tiles).
func _reach_positions(t: Vector2i, mode: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if mode == DesignationMap.Kind.DIG:
		if not (grid.is_passable(t + Vector2i.UP) or grid.is_passable(t + Vector2i.DOWN)
				or grid.is_passable(t + Vector2i.LEFT) or grid.is_passable(t + Vector2i.RIGHT)):
			return out
	var c := nav.clearance
	var on_walls: Array[Vector2i] = []
	for fy in range(t.y - 1, t.y + c + 1):
		for fx in range(t.x - 1, t.x + 2):
			if mode == DesignationMap.Kind.BUILD_WALL and fx == t.x and t.y <= fy and t.y >= fy - (c - 1):
				continue
			var f := Vector2i(fx, fy)
			if nav.can_stand(f):
				# Prefer spots whose body keeps clear of other wall orders (QA-3).
				if body_on_wall_order(f):
					on_walls.append(f)
				else:
					out.append(f)
	return out if not out.is_empty() else on_walls


func _dig_ticks(t: Vector2i) -> int:
	var def := grid.registry.get_def(grid.get_tile(t))
	var hardness := def.hardness if def != null else 1.0
	return maxi(1, ceili(hardness * DIG_TICKS_PER_HARDNESS))


## First tile at/below t whose tile below is solid (items fall). A solid t
## is first moved up to the nearest open tile.
func _landing(t: Vector2i) -> Vector2i:
	var p := Vector2i(clampi(t.x, 0, grid.width - 1), clampi(t.y, 0, grid.height - 1))
	while p.y > 0 and grid.is_solid_at(p):
		p.y -= 1
	while not grid.is_solid_at(p + Vector2i.DOWN):
		p.y += 1
	return p


func _fallback_tile() -> Vector2i:
	var zones := stockpiles.tiles()
	if not zones.is_empty():
		return zones[0]
	var colony := _colony
	if colony != null:
		for npc in colony.all_npcs():
			return npc.tile
	return _landing(Vector2i(grid.width / 2, 0))


func _idx(p: Vector2i) -> int:
	return p.y * grid.width + p.x


func _tile_of(idx: int) -> Vector2i:
	return Vector2i(idx % grid.width, idx / grid.width)


## Every NPC -> ground drop goes through here: the stack lands on the first
## tile at/below `tile` with a solid tile directly beneath (same rule as item
## gravity), so nothing is left floating on a ladder mid-shaft (QA-9).
func _put_down(npc_id: String, tile: Vector2i) -> CommandResult:
	return inventory.drop(npc_id, _landing(tile))
