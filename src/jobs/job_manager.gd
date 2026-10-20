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

var _jobs: Dictionary = {}           # job id -> Job (creation order)
var _by_tile: Dictionary = {}        # tile index -> job id (dig / build)
var _item_res: Dictionary = {}       # reserved ground item id -> job id
var _site_kg: Dictionary = {}        # build job id -> kg delivered (mirror of Inventory)
var _ground: Dictionary = {}         # ground item id -> true (cache from items_changed)
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


func _init(world_grid: WorldGrid, designation_map: DesignationMap, inv: Inventory,
		zones: StockpileZones, nav_grid: NavGrid, id_alloc: StableIdAllocator) -> void:
	grid = world_grid
	designations = designation_map
	inventory = inv
	stockpiles = zones
	nav = nav_grid
	ids = id_alloc
	_chunks_x = grid.chunks_x()
	_prio_count.resize(DesignationMap.MAX_PRIORITY + 1)
	designations.designations_changed.connect(_on_designations_changed)
	grid.tiles_changed.connect(_on_tiles_changed)
	inventory.items_changed.connect(_on_items_changed)
	stockpiles.zones_changed.connect(_on_zones_changed)
	_rebuild_ground()
	_sync_all_designations()


## Called by Colony's constructor (Colony is created after JobManager, §7).
func attach_colony(colony: Colony) -> void:
	_colony_ref = weakref(colony)


# --- Contract API -------------------------------------------------------

func update(tick: int) -> void:
	_tick = tick
	if _reconcile_pending:
		revalidate()
	_expire_unreachable(tick)
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


## Job on an order tile (dig / build), or null.
func job_at(tile: Vector2i) -> Job:
	if not grid.in_bounds(tile):
		return null
	return _jobs.get(_by_tile.get(_idx(tile), ""))


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
			if it == null or it.holder != Inventory.Holder.GROUND:
				errors.append("%s reserves %s which is not on the ground" % [job.id, job.item_id])
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
		if job.kind != Job.KIND_HAUL:
			if designations.get_kind(job.tile) != job.order_kind:
				errors.append("%s has no matching order at %s" % [job.id, job.tile])
			if _by_tile.get(_idx(job.tile), "") != job.id:
				errors.append("%s missing from tile index" % job.id)
			if job.kind == Job.KIND_BUILD and absf(_site(job) - inventory.site_kg(job.id)) > KG_EPSILON:
				errors.append("%s site kg mirror %.3f != %.3f" % [job.id, _site(job), inventory.site_kg(job.id)])
		elif job.item_id.is_empty() and job.carried_id.is_empty():
			errors.append("haul %s has no item" % job.id)
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
	for it in inventory.all_items():
		if it.holder == Inventory.Holder.SITE:
			var sj: Job = _jobs.get(it.holder_id)
			if sj == null or sj.kind != Job.KIND_BUILD:
				errors.append("site item %s belongs to missing build job %s" % [it.id, it.holder_id])
		elif it.holder == Inventory.Holder.NPC and colony != null and colony.get_npc(it.holder_id) == null:
			errors.append("item %s held by missing NPC %s" % [it.id, it.holder_id])
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
		Job.KIND_BUILD:
			return _drive_build(job, npc)
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
	match job.kind:
		Job.KIND_HAUL:
			return job.phase == Job.PHASE_DELIVER and stockpiles.booked_tile(job.id) == NO_TILE
		Job.KIND_DIG:
			return not _work_goals(job).has(dest)
		Job.KIND_BUILD:
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
			_unassign(job)  # deletes the haul job, drops what it carried here
			_set_item_unreachable(iid, tick)
		Job.KIND_BUILD:
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
			inventory.drop(npc.id, npc.tile)
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
	return {"jobs": out}


## Restores jobs and re-validates every reservation against Inventory,
## StockpileZones and (if attached) Colony; anything inconsistent is released.
## Orders without a job get a new one. Load Colony BEFORE JobManager (or call
## revalidate() after both are loaded). Returns the number of dropped entries.
func load_snapshot(s: Dictionary) -> int:
	_jobs.clear()
	_by_tile.clear()
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
	nav.invalidate_all()
	_geom_version += 1
	_rebuild_ground()
	var dropped := 0
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
			if sj == null or sj.kind != Job.KIND_BUILD:
				orphan_sites[it.holder_id] = true
			else:
				_site_kg[sj.id] = float(_site_kg.get(sj.id, 0.0)) + it.kg
	for jid: String in orphan_sites:
		var t: Vector2i = dropped_tiles.get(jid, _fallback_tile())
		inventory.return_site_to_ground(jid, _landing(t))
	# Bookings must belong to a live haul job.
	for b: Dictionary in stockpiles.to_snapshot()["bookings"]:
		var hj: Job = _jobs.get(b["job_id"])
		if hj == null or hj.kind != Job.KIND_HAUL:
			stockpiles.release(b["job_id"])
	_sync_all_designations()
	_reconcile_pending = true
	if _colony != null:
		revalidate()
	_queue_all_loose()
	jobs_changed.emit()
	return dropped


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
				inventory.drop(it.holder_id, npc.tile if npc != null else _landing(job.tile))
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
				inventory.drop(npc.id, npc.tile)
	for it in inventory.all_items():
		if it.holder == Inventory.Holder.NPC and colony.get_npc(it.holder_id) == null:
			inventory.drop(it.holder_id, _fallback_tile())
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
	var rec := ConstructionDefs.recipe(job.order_kind)
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
				var it := _reserved_ground_item(job)
				if it == null:
					_release_item(job)
					var nid := _find_material(job, npc)
					if nid.is_empty():
						_give_up(job, REASON_NO_MATERIAL)
						return {"action": ACTION_NONE}
					_reserve(nid, job)
					it = inventory.get_item(nid)
				var goals := _reach_positions(it.tile, -1)
				if goals.is_empty():
					_set_item_unreachable(it.id, _tick)
					_release_item(job)
					return {"action": ACTION_WAIT}
				if not goals.has(npc.tile):
					return {"action": ACTION_GOTO, "goals": goals}
				var want := minf(need - _site(job), Inventory.CARRY_CAPACITY_KG)
				var r := inventory.pick_up(it.id, npc.id, want)
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
				if job.order_kind == DesignationMap.Kind.BUILD_WALL:
					if _colony != null and _colony.npc_at(job.tile) != null:
						job.wait_reason = REASON_BLOCKED
						return {"action": ACTION_WAIT}
					if inventory.ground_kg_at(job.tile) > 0.0:
						job.wait_reason = REASON_ITEMS_IN_WAY  # a wall would bury them
						return {"action": ACTION_WAIT}
				job.wait_reason = ""
				job.work_ticks += 1
				var total := maxi(1, int(rec["work_ticks"]))
				npc.work_progress = minf(1.0, float(job.work_ticks) / total)
				if job.work_ticks >= total:
					_complete_build(job)
					return {"action": ACTION_NONE}
				return {"action": ACTION_WORK}
			_:
				job.phase = Job.PHASE_FETCH
	return {"action": ACTION_WAIT}


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
				var bt := stockpiles.booked_tile(job.id)
				if bt != NO_TILE:
					stockpiles.book(bt, picked.kg, job.id)  # resize; keeps old booking on failure
				job.phase = Job.PHASE_DELIVER
			Job.PHASE_DELIVER:
				var carried := inventory.carried_by(npc.id)
				if carried == null or carried.id != job.carried_id:
					job.carried_id = ""
					_unassign(job)
					return {"action": ACTION_NONE}
				var t := stockpiles.booked_tile(job.id)
				if t == NO_TILE:
					t = stockpiles.find_drop_tile(carried.kg, npc.tile)
					if t == NO_TILE or not stockpiles.book(t, carried.kg, job.id).ok:
						_finish_haul_here(job, npc)
						return {"action": ACTION_NONE}
				var goals := _reach_positions(t, -1)
				if goals.is_empty():
					stockpiles.release(job.id)
					_finish_haul_here(job, npc)
					return {"action": ACTION_NONE}
				if not goals.has(npc.tile):
					return {"action": ACTION_GOTO, "goals": goals}
				inventory.drop(npc.id, t)
				job.carried_id = ""
				_remove_finished(job)
				return {"action": ACTION_NONE}
			_:
				job.phase = Job.PHASE_FETCH
	return {"action": ACTION_WAIT}


## No stockpile space any more: drop the stack where the NPC stands.
func _finish_haul_here(job: Job, npc: Npc) -> void:
	inventory.drop(npc.id, npc.tile)
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
	var wall := job.order_kind == DesignationMap.Kind.BUILD_WALL
	var ok := grid.can_place_structure(job.tile, WorldGrid.Structure.LADDER)
	if wall:
		ok = grid.can_build(grid.get_tile(job.tile)) \
				and grid.get_structure(job.tile) == WorldGrid.Structure.NONE
	if not ok:
		_cancel(job)
		return
	job.phase = Job.PHASE_DONE
	inventory.consume_site(job.id)
	_site_kg.erase(job.id)
	if wall:
		grid.apply_edit(Rect2i(job.tile, Vector2i.ONE), WorldGrid.Edit.BUILD_WALL)
	else:
		grid.apply_structure(job.tile, WorldGrid.Structure.LADDER)
	_remove_finished(job)


# --- Assignment helpers -------------------------------------------------

## Best open jobs for npc: highest priority, then nearest. Scans chunk rings
## around the NPC and stops once no unseen job can beat the K-th best; a
## confined NPC only looks at chunks around its known region.
func _top_candidates(npc: Npc, tick: int) -> Array[Job]:
	var best: Array[Job] = []
	var scores: Array[int] = []
	if npc._region_valid:
		for c in grid.chunks_in_rect(npc._region_bbox.grow(nav.clearance + 1)):
			_scan_bucket(grid.chunk_index(c), npc, tick, best, scores, true)
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
					_scan_bucket(cy * _chunks_x + cx, npc, tick, best, scores, false)
				dx += 1 if edge or r == 0 else 2 * r
		if best.size() >= ASSIGN_CANDIDATES:
			var kth := best[ASSIGN_CANDIDATES - 1]
			var kth_d := kth.priority * 1000000 - scores[ASSIGN_CANDIDATES - 1]
			if kth.priority >= p_max and kth_d <= r * WorldGrid.CHUNK_SIZE:
				break
	return best


func _scan_bucket(ci: int, npc: Npc, tick: int, best: Array[Job], scores: Array[int],
		region_only: bool) -> void:
	var bucket: Variant = _open_chunks.get(ci)
	if bucket == null:
		return
	for job: Job in (bucket as Dictionary).values():
		if not npc.work_enabled.get(job.kind, false) or npc.is_ignoring(job.id, tick):
			continue
		if int(job._marks.get(npc.id, -1)) > tick:
			continue
		if region_only and not npc._region_reach.has(_idx(job.tile)):
			continue
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
		Job.KIND_DIG:
			goals = _work_goals(job)
		Job.KIND_BUILD:
			var work := _work_goals(job)
			if work.is_empty():
				return {"reason": REASON_UNREACHABLE}
			if npc._region_valid and not _any_in_region(work, npc):
				return {"reason": "site out of reach"}
			var need := float(ConstructionDefs.recipe(job.order_kind)["kg"])
			if _site(job) + KG_EPSILON >= need:
				goals = work
			else:
				item_id = _find_material(job, npc)
				if item_id.is_empty():
					return {"reason": "no material in reach" if npc._region_valid else REASON_NO_MATERIAL}
				goals = _reach_positions(inventory.get_item(item_id).tile, -1)
				if goals.is_empty():
					_set_item_unreachable(item_id, _tick)
					return {"reason": "material unreachable"}
		Job.KIND_HAUL:
			var it := _reserved_ground_item(job)
			if it == null:
				return {"reason": "item gone"}
			goals = _reach_positions(it.tile, -1)
			if goals.is_empty():
				_set_item_unreachable(it.id, _tick)
				return {"reason": "item unreachable"}
			if npc._region_valid:
				var bt := stockpiles.booked_tile(job.id)
				if bt == NO_TILE or not npc._region_reach.has(_idx(bt)):
					return {"reason": "stockpile out of reach"}
	if goals.is_empty():
		return {"reason": REASON_UNREACHABLE}
	return {"goals": goals, "item_id": item_id}


func _assign(job: Job, npc: Npc, item_id: String) -> void:
	job.worker_id = npc.id
	npc.job_id = job.id
	job.wait_reason = ""
	match job.kind:
		Job.KIND_DIG:
			job.phase = Job.PHASE_WORK
		Job.KIND_BUILD:
			if not item_id.is_empty():
				_reserve(item_id, job)
				job.phase = Job.PHASE_FETCH
			else:
				job.phase = Job.PHASE_WORK
		Job.KIND_HAUL:
			job.phase = Job.PHASE_FETCH
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
func _find_material(job: Job, npc: Npc) -> String:
	var mats: Array = ConstructionDefs.recipe(job.order_kind).get("materials", [])
	var near := npc.tile
	var best := ""
	var best_d := 0
	for iid: String in _ground:
		var it := inventory.get_item(iid)
		if it == null or it.holder != Inventory.Holder.GROUND or not (it.material in mats):
			continue
		if int(_item_unreachable.get(iid, -1)) > _tick:
			continue
		if npc._region_valid and not npc._region_reach.has(_idx(it.tile)):
			continue
		var owner_id: String = _item_res.get(iid, "")
		if not owner_id.is_empty():
			var oj: Job = _jobs.get(owner_id)
			if oj == null or oj.kind != Job.KIND_HAUL or not oj.worker_id.is_empty():
				continue
		var d := absi(it.tile.x - near.x) + absi(it.tile.y - near.y)
		if best.is_empty() or d < best_d:
			best = iid
			best_d = d
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
	if _all_blocked(job, tick):
		_set_job_unreachable(job, tick)


func _all_blocked(job: Job, tick: int) -> bool:
	var colony := _colony
	if colony == null:
		return false
	var eligible := 0
	for npc in colony.all_npcs():
		if not npc.work_enabled.get(job.kind, false):
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
	job.unreachable_until = tick + UNREACHABLE_RETRY_TICKS
	job.wait_reason = REASON_UNREACHABLE
	_add_marked(job)
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
				inventory.drop(w, drop_tile)
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
	if job.kind == Job.KIND_BUILD and inventory.site_kg(job.id) > 0.0:
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
	if job.kind != Job.KIND_HAUL and grid.in_bounds(job.tile) \
			and _by_tile.get(_idx(job.tile), "") == job.id:
		_by_tile.erase(_idx(job.tile))
	_release_item(job)
	stockpiles.release(job.id)
	_site_kg.erase(job.id)
	_refresh_open(job)
	job.phase = Job.PHASE_DONE
	jobs_changed.emit()


func _restore_job(job: Job, carried_claims: Dictionary) -> bool:
	if job.is_done():
		return false
	if job.kind == Job.KIND_HAUL:
		job.order_kind = DesignationMap.Kind.NONE
	else:
		var want := designations.get_kind(job.tile)
		var kind_ok := (job.kind == Job.KIND_DIG and job.order_kind == DesignationMap.Kind.DIG) \
				or (job.kind == Job.KIND_BUILD and job.order_kind in
						[DesignationMap.Kind.BUILD_WALL, DesignationMap.Kind.BUILD_LADDER])
		if not kind_ok or want != job.order_kind or _by_tile.has(_idx(job.tile)):
			return false
		job.priority = designations.get_priority(job.tile)
	if not job.item_id.is_empty():
		var it := inventory.get_item(job.item_id)
		if it == null or it.holder != Inventory.Holder.GROUND or _item_res.has(job.item_id):
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
			Job.KIND_DIG:
				job.phase = Job.PHASE_WORK
			Job.KIND_BUILD:
				if not job.carried_id.is_empty():
					job.phase = Job.PHASE_DELIVER
				elif job.phase != Job.PHASE_WORK:
					job.phase = Job.PHASE_FETCH
			Job.KIND_HAUL:
				job.phase = Job.PHASE_DELIVER if not job.carried_id.is_empty() else Job.PHASE_FETCH
	if job.kind == Job.KIND_HAUL and job.worker_id.is_empty() and job.item_id.is_empty():
		return false
	_jobs[job.id] = job
	if not job.carried_id.is_empty():
		carried_claims[job.carried_id] = job.id
	if job.kind != Job.KIND_HAUL:
		_by_tile[_idx(job.tile)] = job.id
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


## Makes the job on tile index match its order. True if anything changed.
func _sync_tile(idx: int) -> bool:
	var kind: int = designations.entries().get(idx, DesignationMap.Kind.NONE)
	var job: Job = _jobs.get(_by_tile.get(idx, ""))
	if job != null and job.is_done():
		return false
	var changed := false
	if job != null and job.order_kind != kind:
		_cancel(job)
		job = null
		changed = true
	if kind == DesignationMap.Kind.NONE:
		return changed
	var tile := _tile_of(idx)
	if job == null:
		job = Job.new()
		job.id = ids.allocate(ID_CATEGORY)
		job.kind = Job.KIND_DIG if kind == DesignationMap.Kind.DIG else Job.KIND_BUILD
		job.order_kind = kind
		job.tile = tile
		job.priority = designations.get_priority(tile)
		_jobs[job.id] = job
		_by_tile[idx] = job.id
		_refresh_open(job)
		return true
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
		var job := Job.new()
		job.id = ids.allocate(ID_CATEGORY)
		job.kind = Job.KIND_HAUL
		job.order_kind = DesignationMap.Kind.NONE
		job.tile = it.tile
		job.priority = HAUL_PRIORITY
		if not stockpiles.book(zone_tiles[best], kg, job.id).ok:
			_haul_retry[iid] = true
			continue
		free[best] -= kg
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
	for it in inventory.all_items():
		if it.holder == Inventory.Holder.GROUND:
			_ground[it.id] = true


func _on_items_changed(item_id: String) -> void:
	if item_id.is_empty():
		_rebuild_ground()
		_queue_all_loose()
		return
	var it := inventory.get_item(item_id)
	if it != null and it.holder == Inventory.Holder.GROUND:
		_ground[item_id] = true
		_queue_item(item_id)
	else:
		_ground.erase(item_id)


func _on_zones_changed(rect: Rect2i) -> void:
	for iid: String in _haul_retry:
		_queue_item(iid)
	_haul_retry.clear()
	# Items on tiles that stopped being stockpile are loose again.
	for iid: String in _ground:
		var it := inventory.get_item(iid)
		if it != null and rect.has_point(it.tile):
			_queue_item(iid)


# --- Geometry ----------------------------------------------------------

func _on_tiles_changed(rect: Rect2i) -> void:
	_geom_version += 1
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
		for iid: String in _item_unreachable.keys():
			var it := inventory.get_item(iid)
			if it == null or int(_item_unreachable[iid]) <= _tick or area.has_point(it.tile):
				_item_unreachable.erase(iid)
	var colony := _colony
	if colony != null:
		var m := nav.clearance + NavGrid.MAX_DROP + 2
		for npc: Npc in colony._npcs.values():
			if npc._region_valid and npc._region_bbox.grow(m).intersects(rect):
				npc._region_valid = false


## Cached work positions of a dig/build job.
func _work_goals(job: Job) -> Array[Vector2i]:
	if job._goals_version != _geom_version or job._goals_key != job.tile:
		job._goals = _reach_positions(job.tile, job.order_kind)
		job._goals_version = _geom_version
		job._goals_key = job.tile
	return job._goals


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
	for fy in range(t.y - 1, t.y + c + 1):
		for fx in range(t.x - 1, t.x + 2):
			if mode == DesignationMap.Kind.BUILD_WALL and fx == t.x and t.y <= fy and t.y >= fy - (c - 1):
				continue
			var f := Vector2i(fx, fy)
			if nav.can_stand(f):
				out.append(f)
	return out


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
