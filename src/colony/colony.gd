class_name Colony
extends RefCounted
## All NPCs of the loaded world (M2 contract §7): identity, movement, intent
## and player commands. Colony moves NPCs tile by tile on simulation ticks
## (rendering interpolates prev_tile -> tile by move_progress) and asks
## JobManager what to do; it never touches Inventory or WorldGrid itself
## (spec §3). Per tick the order of NPC updates rotates so the shared path
## budget (NavGrid.PATH_BUDGET_PER_TICK) is spread fairly.

signal npcs_changed

const START_NPCS := 3                 # plan P-1
const STOP_IGNORE_TICKS := 50         # PLACEHOLDER: "Stop job" keeps the NPC off that job
const IDLE_RETRY_TICKS := 10          # PLACEHOLDER: idle NPC with no job retries after this
const MOVE_SEARCH_RADIUS := 6         # PLACEHOLDER: "Move here" looks this far for a standable tile
const MOVE_SEARCH_GROUPS := 4         # PLACEHOLDER: distance rings tried by "Move here"
const START_SEARCH_COLUMNS := 64      # columns scanned around the centre for start tiles
const START_SPACING := 2
const NAME_TRIES := 64
const ID_CATEGORY := &"npc"
const NO_TILE := Vector2i(-1, -1)

var grid: WorldGrid
var nav: NavGrid
var jobs: JobManager
var ids: StableIdAllocator
var world_seed: int

var _npcs: Dictionary = {}       # npc id -> Npc (spawn order)
var _full_names: Dictionary = {} # full name -> npc id
var _nicknames: Dictionary = {}  # nickname -> npc id
var _spawn_counter: int = 0
var _tick: int = 0
var _rotation: int = 0


func _init(world_grid: WorldGrid, nav_grid: NavGrid, job_manager: JobManager,
		id_alloc: StableIdAllocator, seed_value: int) -> void:
	grid = world_grid
	nav = nav_grid
	jobs = job_manager
	ids = id_alloc
	world_seed = seed_value
	jobs.attach_colony(self)


# --- Queries ------------------------------------------------------------

func all_npcs() -> Array[Npc]:
	var out: Array[Npc] = []
	for n: Npc in _npcs.values():
		out.append(n)
	return out


func get_npc(id: String) -> Npc:
	return _npcs.get(id)


func count() -> int:
	return _npcs.size()


## Any NPC whose body covers tile (while moving: at either end of the step).
func npc_at(tile: Vector2i) -> Npc:
	for n: Npc in _npcs.values():
		if _covers(n.tile, tile) or (n._moving and _covers(n.prev_tile, tile)):
			return n
	return null


# --- Spawning -----------------------------------------------------------

## New NPC with a unique Thai name (per-world seeded RNG). The caller picks a
## standable tile; a non-standable one makes the NPC fall on its first update.
func spawn_npc(tile: Vector2i) -> Npc:
	var n := Npc.new()
	n.id = ids.allocate(ID_CATEGORY)
	var rng := RandomNumberGenerator.new()
	rng.seed = _name_seed(_spawn_counter)
	_spawn_counter += 1
	_pick_names(n, rng)
	n.tile = tile
	n.prev_tile = tile
	n.work_enabled = {&"dig": true, &"build": true, &"haul": true}
	_npcs[n.id] = n
	jobs.on_npcs_changed()
	npcs_changed.emit()
	return n


## START_NPCS on standable surface tiles near the world's centre column.
func spawn_starting_npcs() -> void:
	var spots := starting_tiles(START_NPCS)
	for t in spots:
		spawn_npc(t)


## Standable surface tiles (first standable tile from the top of a column)
## around the centre column, START_SPACING apart when possible.
func starting_tiles(n: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var cx := grid.width / 2
	for spacing in [START_SPACING, 1]:
		out.clear()
		for i in START_SEARCH_COLUMNS * 2:
			var off := (i + 1) / 2 * (1 if i % 2 == 1 else -1)
			var x := cx + off
			if x < 0 or x >= grid.width:
				continue
			var ok := true
			for prev in out:
				if absi(prev.x - x) < spacing:
					ok = false
			if not ok:
				continue
			var spot := _surface_tile(x)
			if spot != NO_TILE:
				out.append(spot)
				if out.size() >= n:
					return out
	return out


# --- Commands -----------------------------------------------------------

## "Move here": releases the current job cleanly (carried item dropped where
## the NPC stands) and walks to the nearest standable tile to `tile`.
## Fails (state unchanged) when no such tile is reachable.
func command_move(npc_id: String, tile: Vector2i) -> CommandResult:
	var n: Npc = _npcs.get(npc_id)
	if n == null:
		return CommandResult.failure(&"unknown_npc", "No NPC %s" % npc_id)
	if not grid.in_bounds(tile):
		return CommandResult.failure(&"out_of_bounds", "Target is outside the world")
	var groups := _stand_groups_near(tile)
	if groups.is_empty():
		return CommandResult.failure(&"no_standable_tile", "No place to stand near %s" % tile)
	var goal := NO_TILE
	var path: Array[Vector2i] = []
	for g: Array[Vector2i] in groups:
		if g.has(n.tile):
			goal = n.tile
			break
		path = nav.find_path(n.tile, g)
		if not path.is_empty():
			goal = path[path.size() - 1]
			break
	if goal == NO_TILE:
		return CommandResult.failure(&"unreachable", "%s cannot reach %s" % [n.nickname, tile])
	jobs.release_npc(n)
	n.command_target = goal
	n._path = path
	_refresh_state(n)
	npcs_changed.emit()
	return CommandResult.success({"target": goal, "steps": path.size()})


## "Stop job": releases the job; the NPC ignores it for STOP_IGNORE_TICKS.
func command_stop(npc_id: String) -> CommandResult:
	var n: Npc = _npcs.get(npc_id)
	if n == null:
		return CommandResult.failure(&"unknown_npc", "No NPC %s" % npc_id)
	var jid := jobs.release_npc(n)
	n.command_target = NO_TILE
	n._path.clear()
	if not jid.is_empty():
		n._ignore_job_id = jid
		n._ignore_until = _tick + STOP_IGNORE_TICKS
	n._next_assign_tick = _tick + 1
	_refresh_state(n)
	npcs_changed.emit()
	return CommandResult.success({"released_job": jid})


func set_work_enabled(npc_id: String, work: StringName, on: bool) -> CommandResult:
	var n: Npc = _npcs.get(npc_id)
	if n == null:
		return CommandResult.failure(&"unknown_npc", "No NPC %s" % npc_id)
	if not (work in Npc.WORK_KEYS):
		return CommandResult.failure(&"invalid_work", "Unknown work type '%s'" % work)
	n.work_enabled[work] = on
	if on:
		jobs.on_npcs_changed()
	elif not n.job_id.is_empty():
		var job := jobs.get_job(n.job_id)
		if job != null and job.kind == work:
			jobs.release_npc(n)
	npcs_changed.emit()
	return CommandResult.success({"work": work, "on": on})


# --- Simulation ---------------------------------------------------------

func update(tick: int) -> void:
	_tick = tick
	var list := _npcs.values()
	var n := list.size()
	if n == 0:
		return
	_rotation = (_rotation + 1) % n
	for i in n:
		_update_npc(list[(i + _rotation) % n], tick)


func _update_npc(n: Npc, tick: int) -> void:
	if n._moving:
		n.move_progress += 1.0 / n._step_ticks
		if n.move_progress < 0.999:
			return
		n._moving = false
		n.move_progress = 0.0
		n.prev_tile = n.tile
	if not nav.can_stand(n.tile):
		_fall(n)
		return
	if not n._path.is_empty() and not n.job_id.is_empty() and jobs.needs_new_route(n):
		n._path.clear()  # destination changed (e.g. stockpile booking lost): ask the job again
	if not n._path.is_empty():
		_start_step(n)
		return
	if n.command_target != NO_TILE:
		if n.tile == n.command_target:
			n.command_target = NO_TILE
			_refresh_state(n)
		else:
			_path_to(n, [n.command_target], tick)
		return
	if not n.job_id.is_empty():
		_drive_job(n, tick)
		return
	n.work_progress = 0.0
	n.state = &"idle"
	if tick < n._next_assign_tick or nav.budget_left(tick) <= 0:
		return
	var r := jobs.try_assign(n, tick)
	if r.ok:
		n._path = r.data["path"]
		if not n._path.is_empty():
			_start_step(n)
	elif r.code == &"no_job":
		n._next_assign_tick = tick + IDLE_RETRY_TICKS


func _drive_job(n: Npc, tick: int) -> void:
	var a := jobs.drive(n, tick)
	match a["action"]:
		JobManager.ACTION_GOTO:
			var goals: Array[Vector2i] = a["goals"]
			if not nav.consume_budget(tick):
				_refresh_state(n)
				return  # wait for budget on a later tick
			var path := nav.find_path(n.tile, goals)
			if path.is_empty():
				jobs.report_unreachable(n, tick)
				_refresh_state(n)
				return
			n._path = path
			_start_step(n)
		JobManager.ACTION_WORK:
			n.state = &"working"
		_:
			if n.job_id.is_empty():
				n.work_progress = 0.0
			_refresh_state(n)


## Path search for a non-job destination (command repaths), budgeted.
func _path_to(n: Npc, goals: Array[Vector2i], tick: int) -> void:
	if not nav.consume_budget(tick):
		return
	var path := nav.find_path(n.tile, goals)
	if path.is_empty():
		n.command_target = NO_TILE  # target no longer reachable: give up the command
		_refresh_state(n)
		return
	n._path = path
	_start_step(n)


## Starts the next path step after validating it; an invalid step triggers
## a repath (job: on the next drive; command: right away if budget allows).
func _start_step(n: Npc) -> void:
	var next: Vector2i = n._path[0]
	var cost := nav.move_cost(n.tile, next)
	if cost < 0:
		n._path.clear()
		_refresh_state(n)
		return
	n._path.remove_at(0)
	n.prev_tile = n.tile
	n.tile = next
	n._step_ticks = maxi(1, cost)
	n.move_progress = 0.0  # advances on each of the next _step_ticks ticks
	n._moving = true
	_refresh_state(n)


## Gravity: the floor vanished. Fall straight down to the first standable
## tile (TICKS_PER_DROP_TILE per tile, no damage in M2); the current work
## step restarts, carried items stay carried.
func _fall(n: Npc) -> void:
	n._path.clear()
	jobs.on_npc_fell(n)
	var landing := NO_TILE
	for y in range(n.tile.y + 1, grid.height):
		var p := Vector2i(n.tile.x, y)
		if nav.can_stand(p):
			landing = p
			break
		if grid.is_solid_at(p):
			break
	if landing == NO_TILE:
		landing = _nearest_standable(n.tile)
		if landing == NO_TILE:
			return
		n.prev_tile = landing  # no straight fall possible: placed, not animated
		n.tile = landing
		n.move_progress = 0.0
		n._moving = false
		_refresh_state(n)
		return
	n.prev_tile = n.tile
	n.tile = landing
	n._step_ticks = maxi(1, NavGrid.TICKS_PER_DROP_TILE * (landing.y - n.prev_tile.y))
	n.move_progress = 0.0
	n._moving = true
	_refresh_state(n)


func _refresh_state(n: Npc) -> void:
	if n._moving or not n._path.is_empty():
		n.state = &"carrying" if jobs.inventory.carried_by(n.id) != null else &"moving"
	else:
		n.state = &"idle"


## Called by JobManager when an NPC's job link ends (finish/cancel/release).
func _on_job_released(n: Npc) -> void:
	n.job_id = ""
	n.work_progress = 0.0
	if n.command_target == NO_TILE:
		n._path.clear()
	_refresh_state(n)


# --- Persistence --------------------------------------------------------

func to_snapshot() -> Dictionary:
	var list: Array = []
	for n: Npc in _npcs.values():
		var we := {}
		for k: StringName in Npc.WORK_KEYS:
			we[String(k)] = bool(n.work_enabled.get(k, true))
		list.append({
			"id": n.id,
			"full_name": n.full_name,
			"nickname": n.nickname,
			"tile": n.tile,
			"job_id": n.job_id,
			"work_enabled": we,
			"command_target": n.command_target,
			"ignore_job_id": n._ignore_job_id,
			"ignore_until": n._ignore_until,
		})
	return {"npcs": list, "spawn_counter": _spawn_counter, "tick": _tick}


## Restores NPCs (paths are recomputed). NPCs on tiles that are no longer
## standable are moved to the nearest standable tile. Load Colony before
## JobManager; JobManager.load_snapshot reconciles job links.
## Returns the number of dropped entries.
func load_snapshot(s: Dictionary) -> int:
	_npcs.clear()
	_full_names.clear()
	_nicknames.clear()
	nav.invalidate_all()
	var dropped := 0
	var sc: Variant = s.get("spawn_counter", 0)
	var tk: Variant = s.get("tick", 0)
	_spawn_counter = maxi(0, sc) if typeof(sc) == TYPE_INT else 0
	_tick = tk if typeof(tk) == TYPE_INT else 0
	var list_v: Variant = s.get("npcs")
	if typeof(list_v) == TYPE_ARRAY:
		for e: Variant in list_v:
			var n := _npc_from(e)
			if n == null or _npcs.has(n.id) or _full_names.has(n.full_name) \
					or _nicknames.has(n.nickname):
				dropped += 1
				continue
			if not nav.can_stand(n.tile):
				var t := _nearest_standable(n.tile)
				if t != NO_TILE:
					n.tile = t
			n.prev_tile = n.tile
			_npcs[n.id] = n
			_full_names[n.full_name] = n.id
			_nicknames[n.nickname] = n.id
	_spawn_counter = maxi(_spawn_counter, _npcs.size())
	npcs_changed.emit()
	return dropped


func _npc_from(e: Variant) -> Npc:
	if typeof(e) != TYPE_DICTIONARY:
		return null
	var d: Dictionary = e
	for k: String in ["id", "full_name", "nickname", "job_id"]:
		if typeof(d.get(k, "")) != TYPE_STRING:
			return null
	if typeof(d.get("tile")) != TYPE_VECTOR2I:
		return null
	var n := Npc.new()
	n.id = d["id"]
	if not StableIdAllocator.is_valid(n.id) or StableIdAllocator.category_of(n.id) != ID_CATEGORY:
		return null
	n.full_name = d.get("full_name", "")
	n.nickname = d.get("nickname", "")
	if n.full_name.is_empty() or n.nickname.is_empty():
		return null
	n.tile = d["tile"]
	if not grid.in_bounds(n.tile):
		return null
	n.job_id = d.get("job_id", "")
	var ct: Variant = d.get("command_target", NO_TILE)
	n.command_target = ct if typeof(ct) == TYPE_VECTOR2I and (ct == NO_TILE or grid.in_bounds(ct)) else NO_TILE
	var we: Variant = d.get("work_enabled", {})
	n.work_enabled = {&"dig": true, &"build": true, &"haul": true}
	if typeof(we) == TYPE_DICTIONARY:
		for k: StringName in Npc.WORK_KEYS:
			var v: Variant = (we as Dictionary).get(String(k), true)
			n.work_enabled[k] = v if typeof(v) == TYPE_BOOL else true
	var ij: Variant = d.get("ignore_job_id", "")
	var iu: Variant = d.get("ignore_until", -1)
	n._ignore_job_id = ij if typeof(ij) == TYPE_STRING else ""
	n._ignore_until = iu if typeof(iu) == TYPE_INT else -1
	return n


# --- Internals ----------------------------------------------------------

func _covers(feet: Vector2i, tile: Vector2i) -> bool:
	return tile.x == feet.x and tile.y <= feet.y and tile.y >= feet.y - (nav.clearance - 1)


func _name_seed(counter: int) -> int:
	return (world_seed * 1000003 + counter * 7919 + 17) & 0x7fffffffffffffff


func _pick_names(n: Npc, rng: RandomNumberGenerator) -> void:
	var given := ThaiNames.GIVEN_NAMES
	var sur := ThaiNames.SURNAMES
	var nick := ThaiNames.NICKNAMES
	var full := ""
	for _i in NAME_TRIES:
		full = "%s %s" % [given[rng.randi_range(0, given.size() - 1)], sur[rng.randi_range(0, sur.size() - 1)]]
		if not _full_names.has(full):
			break
	var k := 2
	var base_full := full
	while _full_names.has(full):
		full = "%s %d" % [base_full, k]
		k += 1
	var nickname := ""
	for _i in NAME_TRIES:
		nickname = nick[rng.randi_range(0, nick.size() - 1)]
		if not _nicknames.has(nickname):
			break
	var base_nick := nickname
	k = 2
	while _nicknames.has(nickname):
		nickname = "%s %d" % [base_nick, k]
		k += 1
	n.full_name = full
	n.nickname = nickname
	_full_names[full] = n.id
	_nicknames[nickname] = n.id


func _surface_tile(x: int) -> Vector2i:
	for y in grid.height:
		var p := Vector2i(x, y)
		if grid.is_solid_at(p):
			return p + Vector2i.UP if nav.can_stand(p + Vector2i.UP) else NO_TILE
	return NO_TILE


## Standable tiles within MOVE_SEARCH_RADIUS of t, grouped by Manhattan
## distance (nearest group first, at most MOVE_SEARCH_GROUPS groups).
func _stand_groups_near(t: Vector2i) -> Array:
	var by_d := {}
	for dy in range(-MOVE_SEARCH_RADIUS, MOVE_SEARCH_RADIUS + 1):
		for dx in range(-MOVE_SEARCH_RADIUS, MOVE_SEARCH_RADIUS + 1):
			var d := absi(dx) + absi(dy)
			if d > MOVE_SEARCH_RADIUS:
				continue
			var p := t + Vector2i(dx, dy)
			if nav.can_stand(p):
				if not by_d.has(d):
					var arr: Array[Vector2i] = []
					by_d[d] = arr
				(by_d[d] as Array[Vector2i]).append(p)
	var keys := by_d.keys()
	keys.sort()
	var out: Array = []
	for d: int in keys:
		out.append(by_d[d])
		if out.size() >= MOVE_SEARCH_GROUPS:
			break
	return out


## Nearest standable tile by expanding square rings (straight down first).
func _nearest_standable(t: Vector2i) -> Vector2i:
	for y in range(maxi(0, t.y), grid.height):
		var p := Vector2i(t.x, y)
		if nav.can_stand(p):
			return p
		if grid.is_solid_at(p):
			break
	var max_r := maxi(grid.width, grid.height)
	for r in range(1, max_r):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var p := t + Vector2i(dx, dy)
				if grid.in_bounds(p) and nav.can_stand(p):
					return p
	return NO_TILE
