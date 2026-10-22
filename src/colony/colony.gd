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

# --- M4a needs (all PLACEHOLDER, D-028 / M4a contract §7) ---------------
const HUNGER_PER_TICK := 100.0 / GameTime.TICKS_PER_DAY            # -100 / day
## -100 per 20 h awake (M4A-QA-2): the default 16 h day (06-22) ends at
## stamina 20, tired but above EXHAUSTED; 8 h in a bed (+133) refills it.
const STAMINA_AWAKE_PER_TICK := 100.0 / (20 * GameTime.TICKS_PER_HOUR)
const STAMINA_BED_PER_TICK := 100.0 / (6 * GameTime.TICKS_PER_HOUR)    # +100 / 6 h in bed
const BEDROOM_FACTOR := 1.5                                          # +50 % in a bedroom
const FLOOR_FACTOR := 0.5                                            # x0.5 on the floor
const HEALTH_LOSS_PER_TICK := 100.0 / (GameTime.TICKS_PER_DAY / 2)  # starving or exhausted
const HEALTH_GAIN_PER_TICK := 100.0 / GameTime.TICKS_PER_DAY
const HUNGRY := 40.0           # eats below this
const CRITICAL_HUNGER := 10.0  # refuses work, eats before anything
const EXHAUSTED := 15.0        # sleeps below this whatever the schedule
const RESTED := 100.0          # wakes (when the schedule allows) at this stamina
const RECOVER_HEALTH := 20.0   # a collapsed NPC above this gets up
const DEATH_TICKS := 6000      # collapsed this long (health <= RECOVER_HEALTH) = death (P-2)
const EAT_TICKS_TABLE := 20
const EAT_TICKS_STANDING := 40
const TABLE_NUTRITION_FACTOR := 1.1  # a meal at a table fills a bit more
const FOOD_RETRY_TICKS := 100  # no reachable food: look again after this
const COLONY_CHECK_EVERY := 20 # beds + colony-wide alerts cadence (ticks)
const WALK_OK := 0
const WALK_WAIT := 1
const WALK_FAIL := 2

var grid: WorldGrid
var nav: NavGrid
var jobs: JobManager
var ids: StableIdAllocator
var world_seed: int
## M4a (attach_m4a): needs, schedules, beds, alerts. Off = M2/M3 behaviour.
var needs_enabled: bool = false
var alerts: AlertService = null
var rooms: RoomMap = null

var _npcs: Dictionary = {}       # npc id -> Npc (spawn order)
var _full_names: Dictionary = {} # full name -> npc id
var _nicknames: Dictionary = {}  # nickname -> npc id
var _spawn_counter: int = 0
var _tick: int = 0
var _rotation: int = 0
var _table_users: Dictionary = {}  # table building id -> npc id eating there
var _sleep_factor: Dictionary = {} # npc id -> stamina factor while asleep (bed / bedroom / floor)
var _deaths: int = 0
## Recent deaths [{id, nickname, tile}] (saved): their "died" alerts are
## re-raised after a load (M4A-QA-1). Bounded to RECENT_DEATHS_KEPT.
var _recent_deaths: Array = []
const RECENT_DEATHS_KEPT := 20


func _init(world_grid: WorldGrid, nav_grid: NavGrid, job_manager: JobManager,
		id_alloc: StableIdAllocator, seed_value: int) -> void:
	grid = world_grid
	nav = nav_grid
	jobs = job_manager
	ids = id_alloc
	world_seed = seed_value
	jobs.attach_colony(self)


## M4a wiring (WorldSession, once after construction): turns on needs,
## schedules, eating, sleeping, collapse/death and alerts. JobManager must
## get attach_m4a too (food, farms, kitchens).
func attach_m4a(alert_service: AlertService, room_map: RoomMap) -> void:
	alerts = alert_service
	rooms = room_map
	needs_enabled = true
	var b := jobs.buildings
	if b != null and not b.buildings_changed.is_connected(_on_buildings_changed):
		b.buildings_changed.connect(_on_buildings_changed)
		b.building_lost.connect(_on_building_lost)


func _on_buildings_changed(_rect: Rect2i) -> void:
	_release_missing_furniture()


func _on_building_lost(_id: String, _key: StringName, _origin: Vector2i, _materials: Dictionary) -> void:
	_release_missing_furniture()


## A bed or table that was deconstructed, lost its floor or was removed:
## its owner / sleeper / eater lets go of it (a sleeper keeps sleeping on
## the floor, an eater eats standing) and beds are handed out again.
func _release_missing_furniture() -> void:
	var beds_changed := false
	for n: Npc in _npcs.values():
		if not n.bed_id.is_empty() and not _is_bed(n.bed_id):
			n.bed_id = ""
			beds_changed = true
			if n._activity == &"sleep" and n._in_bed:
				n._in_bed = false
				_sleep_factor[n.id] = FLOOR_FACTOR
			elif n._activity == &"sleep" and n._phase == &"go":
				n._phase = &""  # walking to a bed that is gone: decide again
				if not n._moving:
					n._path.clear()
		if not n._table_id.is_empty() and not _is_table(n._table_id):
			_release_table(n)
			if n._activity == &"eat" and n._phase == &"table" and not n._moving:
				n._path.clear()
	for tid: String in _table_users.keys():
		if not _is_table(tid):
			_table_users.erase(tid)
	_assign_beds()  # a new bed (placed or freed) goes to whoever has none
	if beds_changed:
		npcs_changed.emit()


func deaths() -> int:
	return _deaths


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
	n.work_enabled = _default_work()
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
	if not n.is_ok():
		return CommandResult.failure(&"collapsed", "%s has collapsed and cannot move" % n.nickname)
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
	_end_activity(n)
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
	if not n.is_ok():
		return CommandResult.failure(&"collapsed", "%s has collapsed" % n.nickname)
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
		if job != null and job.work_type() == work:
			jobs.release_npc(n)
	npcs_changed.emit()
	return CommandResult.success({"work": work, "on": on})


## 24 hourly Npc.Activity values (WORK / SLEEP / FREE).
func set_schedule(npc_id: String, hours: PackedByteArray) -> CommandResult:
	var n: Npc = _npcs.get(npc_id)
	if n == null:
		return CommandResult.failure(&"unknown_npc", "No NPC %s" % npc_id)
	var check := _check_schedule(hours)
	if not check.ok:
		return check
	n.schedule = hours.duplicate()
	npcs_changed.emit()
	return CommandResult.success({"npc_id": npc_id})


func set_schedule_all(hours: PackedByteArray) -> CommandResult:
	var check := _check_schedule(hours)
	if not check.ok:
		return check
	for n: Npc in _npcs.values():
		n.schedule = hours.duplicate()
	npcs_changed.emit()
	return CommandResult.success({"count": _npcs.size()})


## bed_id "" = automatic (the next free bed). A bed owned by another NPC is
## taken over (that NPC gets another bed automatically).
func assign_bed(npc_id: String, bed_id: String) -> CommandResult:
	var n: Npc = _npcs.get(npc_id)
	if n == null:
		return CommandResult.failure(&"unknown_npc", "No NPC %s" % npc_id)
	if bed_id.is_empty():
		n.bed_id = ""
		_assign_beds()
		npcs_changed.emit()
		return CommandResult.success({"bed_id": n.bed_id})
	if not _is_bed(bed_id):
		return CommandResult.failure(&"not_bed", "%s is not a bed" % bed_id)
	for o: Npc in _npcs.values():
		if o != n and o.bed_id == bed_id:
			o.bed_id = ""
	n.bed_id = bed_id
	_assign_beds()
	npcs_changed.emit()
	return CommandResult.success({"bed_id": bed_id})


func _check_schedule(hours: PackedByteArray) -> CommandResult:
	if hours.size() != 24:
		return CommandResult.failure(&"invalid_schedule", "A schedule has 24 hours")
	for v in hours:
		if not (v in [Npc.Activity.WORK, Npc.Activity.SLEEP, Npc.Activity.FREE]):
			return CommandResult.failure(&"invalid_schedule", "Unknown activity %d" % v)
	return CommandResult.success()


# --- Simulation ---------------------------------------------------------

func update(tick: int) -> void:
	_tick = tick
	if needs_enabled and tick % COLONY_CHECK_EVERY == 0:
		_assign_beds()
		_colony_alerts()
	var list := _npcs.values()
	var n := list.size()
	if n == 0:
		return
	_rotation = (_rotation + 1) % n
	for i in n:
		var npc: Npc = list[(i + _rotation) % n]
		if _npcs.has(npc.id):  # may have died this tick
			_update_npc(npc, tick)


func _update_npc(n: Npc, tick: int) -> void:
	if needs_enabled:
		_tick_needs(n, tick)
		if not _npcs.has(n.id):
			return  # died
		if not n.is_ok():
			if not nav.can_stand(n.tile):
				_fall(n)
			n.state = &"collapsed"
			return
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
	var may_work := true
	if needs_enabled:
		var want := _desired(n, tick)
		if want == &"eat" or want == &"sleep":
			if not n.job_id.is_empty():
				jobs.release_npc(n)  # a need pre-empts work (reservations released)
				n._path.clear()
			n.command_target = NO_TILE
			if n._activity != want:
				_end_activity(n)
				n._activity = want
				n._phase = &""
			if not n._path.is_empty():
				_start_step(n)
				return
			if want == &"eat":
				_do_eat(n, tick)
			else:
				_do_sleep(n, tick)
			return
		if n._activity != &"":
			_end_activity(n)
		if want == &"free" or n.hunger < CRITICAL_HUNGER:
			# Free time (or too hungry to work): no jobs; player moves still run.
			may_work = false
			if not n.job_id.is_empty():
				jobs.release_npc(n)
			if n._path.is_empty() and n.command_target == NO_TILE:
				n.work_progress = 0.0
				n.state = &"idle"
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
	if not may_work or tick < n._next_assign_tick or nav.budget_left(tick) <= 0:
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
			var path := jobs.find_path_for(n, goals)
			if path.is_empty():
				jobs.report_unreachable(n, tick)
				_refresh_state(n)
				return
			n._path = path
			_start_step(n)
		JobManager.ACTION_WORK:
			n.state = &"working"
		JobManager.ACTION_WAIT:
			n.state = &"waiting"
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
		n.state = &"waiting" if not n.job_id.is_empty() else &"idle"


## Moves an NPC that is not moving out of the way (e.g. it stands on a wall
## site it is not building): its job is released (and ignored for
## STOP_IGNORE_TICKS) and it walks to the nearest standable tile whose body
## covers no wall order. True if it got somewhere to go.
func step_aside(n: Npc, avoid: Rect2i = Rect2i()) -> bool:
	var groups := _stand_groups_near(n.tile, true, avoid)
	var goal := NO_TILE
	var path: Array[Vector2i] = []
	for g: Array[Vector2i] in groups:
		if g.has(n.tile):
			return false  # already clear (should not happen when asked)
		path = nav.find_path(n.tile, g)
		if not path.is_empty():
			goal = path[path.size() - 1]
			break
	if goal == NO_TILE:
		return false
	var jid := jobs.release_npc(n)
	if not jid.is_empty():
		n._ignore_job_id = jid
		n._ignore_until = _tick + STOP_IGNORE_TICKS
	n.command_target = goal
	n._path = path
	_refresh_state(n)
	return true


## Called by JobManager when an NPC's job link ends (finish/cancel/release).
func _on_job_released(n: Npc) -> void:
	n.job_id = ""
	n.work_progress = 0.0
	if n.command_target == NO_TILE:
		n._path.clear()
	_refresh_state(n)


# --- M4a: needs, activities, collapse -------------------------------------

## What the NPC should do now, in priority order (M4a §7): critical hunger
## -> eat; sleep (schedule or exhausted; a sleeper wakes only when rested
## and the schedule no longer says Sleep); hungry and food around -> eat;
## the schedule's Work -> jobs; else free time.
func _desired(n: Npc, tick: int) -> StringName:
	var sched: int = n.schedule[GameTime.hour(tick)] if n.schedule.size() == 24 else Npc.Activity.WORK
	var food_ok := n._activity == &"eat" or (tick >= n._food_retry_tick and jobs.food_exists())
	if n.hunger < CRITICAL_HUNGER and food_ok:
		return &"eat"
	if n._activity == &"eat" and food_ok:
		return &"eat"  # finish the meal first
	if n._activity == &"sleep" and not (n.stamina >= RESTED and sched != Npc.Activity.SLEEP):
		return &"sleep"
	if sched == Npc.Activity.SLEEP or n.stamina < EXHAUSTED:
		return &"sleep"
	if n.hunger < HUNGRY and food_ok:
		return &"eat"
	return &"work" if sched == Npc.Activity.WORK else &"free"


func _tick_needs(n: Npc, tick: int) -> void:
	n.hunger = maxf(0.0, n.hunger - HUNGER_PER_TICK)
	if not n.is_ok():
		n.stamina = minf(100.0, n.stamina + STAMINA_BED_PER_TICK * FLOOR_FACTOR)  # lying down
	elif n._activity == &"sleep" and n._phase == &"asleep":
		n.stamina = minf(100.0, n.stamina + STAMINA_BED_PER_TICK * float(_sleep_factor.get(n.id, FLOOR_FACTOR)))
	else:
		n.stamina = maxf(0.0, n.stamina - STAMINA_AWAKE_PER_TICK)
	if n.hunger <= 0.0 or n.stamina <= 0.0:
		n.health = maxf(0.0, n.health - HEALTH_LOSS_PER_TICK)
	else:
		n.health = minf(100.0, n.health + HEALTH_GAIN_PER_TICK)
	if n.is_ok():
		if n.health <= 0.0:
			_collapse(n, tick)
	elif n.health > RECOVER_HEALTH:
		n.condition = Npc.CONDITION_OK  # gets up
		n._collapsed_since = -1
		n.state = &"idle"
		npcs_changed.emit()
	elif tick - n._collapsed_since >= DEATH_TICKS:
		_die(n)
		return
	_npc_alerts(n)


func _collapse(n: Npc, tick: int) -> void:
	jobs.release_npc(n)
	_end_activity(n)
	jobs.on_npc_down(n)
	n.condition = Npc.CONDITION_COLLAPSED
	n._collapsed_since = tick
	n.command_target = NO_TILE
	n._path.clear()
	n._moving = false
	n.prev_tile = n.tile
	n.move_progress = 0.0
	n.state = &"collapsed"
	npcs_changed.emit()


## Death (P-2): carried items dropped, every reservation released, body
## removed (names stay used). Raises a "died" alert.
func _die(n: Npc) -> void:
	jobs.release_npc(n)
	_end_activity(n)
	jobs.on_npc_down(n)
	n.condition = Npc.CONDITION_DEAD
	n.bed_id = ""
	_npcs.erase(n.id)
	_deaths += 1
	_recent_deaths.append({"id": n.id, "nickname": n.nickname, "tile": n.tile})
	if _recent_deaths.size() > RECENT_DEATHS_KEPT:
		_recent_deaths.pop_front()
	if alerts != null:
		alerts.clear_prefix(n.id + "/")
		_raise_died(_recent_deaths[_recent_deaths.size() - 1])
	jobs.on_npcs_changed()
	jobs.sync_feed_jobs()
	npcs_changed.emit()


## Stops eating / sleeping: drops a carried meal where the NPC stands,
## releases a reserved one and the table.
func _end_activity(n: Npc) -> void:
	jobs.release_food(n)  # also a dangling meal link without an activity (M4A-QA-3)
	if n._activity == &"":
		return
	if not n._table_id.is_empty() and _table_users.get(n._table_id, "") == n.id:
		_table_users.erase(n._table_id)
	n._table_id = ""
	n._activity = &""
	n._phase = &""
	n._eat_ticks = 0
	n._in_bed = false
	_sleep_factor.erase(n.id)
	if not n._moving:
		n._path.clear()


func _do_eat(n: Npc, tick: int) -> void:
	for _step in 3:
		match n._phase:
			&"", &"fetch":
				n._phase = &"fetch"
				var held := jobs.inventory.carried_by(n.id)
				if held != null and held.id == n._food_item:
					n._phase = &"table"
					continue
				if jobs.reserve_food(n).is_empty():
					_give_up_eating(n, tick, FOOD_RETRY_TICKS)
					return
				var goals := jobs.food_goals(n)
				if goals.is_empty():
					jobs.food_unreachable(n)
					_give_up_eating(n, tick, 1)
					return
				if goals.has(n.tile):
					if not jobs.take_food(n):
						_give_up_eating(n, tick, 1)
						return
					n._phase = &"table"
					continue
				if _walk_to(n, goals, tick) == WALK_FAIL:
					jobs.food_unreachable(n)
					_give_up_eating(n, tick, 1)
				return
			&"table":
				if n._table_id.is_empty():
					n._table_id = _claim_table(n)
				if n._table_id.is_empty():
					n._phase = &"eating"
					n._eat_ticks = EAT_TICKS_STANDING
					continue
				var goals := jobs.building_goals(n._table_id)
				if goals.has(n.tile):
					n._phase = &"eating"
					n._eat_ticks = EAT_TICKS_TABLE
					continue
				var w := WALK_FAIL if goals.is_empty() else _walk_to(n, goals, tick)
				if w == WALK_FAIL:
					_release_table(n)  # unreachable table: eat standing
					n._phase = &"eating"
					n._eat_ticks = EAT_TICKS_STANDING
					continue
				return
			&"eating":
				n.state = &"eating"
				n._eat_ticks -= 1
				if n._eat_ticks <= 0:
					jobs.eat(n, TABLE_NUTRITION_FACTOR if not n._table_id.is_empty() else 1.0)
					_end_activity(n)
					n.state = &"idle"
				return
			_:
				n._phase = &"fetch"


func _give_up_eating(n: Npc, tick: int, retry: int) -> void:
	_end_activity(n)
	n._food_retry_tick = tick + retry
	n.state = &"idle"


func _do_sleep(n: Npc, tick: int) -> void:
	match n._phase:
		&"", &"go":
			n._phase = &"go"
			if not _is_bed(n.bed_id):
				_assign_beds()  # a free bed may exist (bed checks are otherwise periodic)
			var bed := n.bed_id if _is_bed(n.bed_id) else ""
			if bed.is_empty():
				_fall_asleep(n, false)
				return
			var spots := _bed_spots(bed)
			if spots.has(n.tile):
				_fall_asleep(n, true)
				return
			var w := WALK_FAIL if spots.is_empty() else _walk_to(n, spots, tick)
			if w == WALK_FAIL:
				_fall_asleep(n, false)  # bed out of reach: floor
		&"asleep":
			n.state = &"sleeping"
		_:
			n._phase = &"go"


func _fall_asleep(n: Npc, in_bed: bool) -> void:
	n._phase = &"asleep"
	n._in_bed = in_bed
	var f := FLOOR_FACTOR
	if in_bed:
		f = 1.0
		if rooms != null and rooms.room_at(n.tile).get("type", &"") == &"bedroom":
			f = BEDROOM_FACTOR
	_sleep_factor[n.id] = f
	n.state = &"sleeping"


## Budgeted path to goals for an activity: WALK_OK (walking), WALK_WAIT (no
## search budget this tick) or WALK_FAIL (no path).
func _walk_to(n: Npc, goals: Array[Vector2i], tick: int) -> int:
	if not nav.consume_budget(tick):
		n.state = &"waiting"
		return WALK_WAIT
	var path := jobs.find_path_for(n, goals)
	if path.is_empty():
		return WALK_FAIL
	n._path = path
	_start_step(n)
	return WALK_OK


func _claim_table(n: Npc) -> String:
	if jobs.buildings == null:
		return ""
	var best := ""
	var best_d := 0
	for bid in jobs.buildings.all_ids():
		var b := jobs.buildings.get_building(bid)
		if b.get("key", &"") != &"table" or _table_users.has(bid):
			continue
		var o: Vector2i = b["origin"]
		var d := absi(o.x - n.tile.x) + absi(o.y - n.tile.y)
		if best.is_empty() or d < best_d:
			best = bid
			best_d = d
	if not best.is_empty():
		_table_users[best] = n.id
	return best


func _release_table(n: Npc) -> void:
	if _table_users.get(n._table_id, "") == n.id:
		_table_users.erase(n._table_id)
	n._table_id = ""


func _is_bed(bid: String) -> bool:
	return not bid.is_empty() and jobs.buildings != null \
			and jobs.buildings.get_building(bid).get("key", &"") == &"bed"


func _is_table(bid: String) -> bool:
	return not bid.is_empty() and jobs.buildings != null \
			and jobs.buildings.get_building(bid).get("key", &"") == &"table"


## Standable tiles of a bed's footprint (the NPC lies on the bed).
func _bed_spots(bid: String) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var b := jobs.buildings.get_building(bid)
	if b.is_empty():
		return out
	var r := jobs.buildings.footprint(b["key"], b["origin"])
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			if nav.can_stand(Vector2i(x, y)):
				out.append(Vector2i(x, y))
	return out


## Every NPC without a (valid) bed gets a free one; owners stay unique.
func _assign_beds() -> void:
	if jobs.buildings == null:
		return
	var owned := {}
	for n: Npc in _npcs.values():
		if not _is_bed(n.bed_id) or owned.has(n.bed_id):
			n.bed_id = ""
		else:
			owned[n.bed_id] = n.id
	var free: Array[String] = []
	for bid in jobs.buildings.all_ids():
		if _is_bed(bid) and not owned.has(bid):
			free.append(bid)
	for n: Npc in _npcs.values():
		if n.bed_id.is_empty() and not free.is_empty():
			n.bed_id = free.pop_front()


func _npc_alerts(n: Npc) -> void:
	if alerts == null:
		return
	_flag(n, "hungry", n.is_ok() and n.hunger < HUNGRY and n.hunger > 0.0,
			AlertService.Severity.GENERAL, "%s is hungry")
	_flag(n, "starving", n.is_ok() and n.hunger <= 0.0, AlertService.Severity.IMPORTANT, "%s is starving")
	_flag(n, "exhausted", n.is_ok() and n.stamina < EXHAUSTED, AlertService.Severity.GENERAL,
			"%s is exhausted")
	_flag(n, "collapsed", n.condition == Npc.CONDITION_COLLAPSED, AlertService.Severity.EMERGENCY,
			"%s has collapsed")


func _flag(n: Npc, what: String, on: bool, severity: AlertService.Severity, text: String) -> void:
	if on == n._alert_flags.has(what):
		return
	var key := "%s/%s" % [n.id, what]
	if on:
		n._alert_flags[what] = true
		alerts.set_alert(key, severity, text % n.nickname, n.tile, n.id)
	else:
		n._alert_flags.erase(what)
		alerts.clear(key)


func _raise_died(d: Dictionary) -> void:
	alerts.set_alert(String(d["id"]) + "/died", AlertService.Severity.EMERGENCY,
			"%s has died" % d["nickname"], d["tile"], d["id"])


## Re-raises every need / colony / death alert from the current state (the
## alert service is not saved). Call after loading, also while paused
## (M4A-QA-6); load_snapshot calls it when alerts are attached.
func refresh_alerts() -> void:
	if alerts == null or not needs_enabled:
		return
	for n: Npc in _npcs.values():
		n._alert_flags.clear()
		for what in ["hungry", "starving", "exhausted", "collapsed"]:
			alerts.clear("%s/%s" % [n.id, what])
		_npc_alerts(n)
	for d: Dictionary in _recent_deaths:
		_raise_died(d)
	_colony_alerts()


func _colony_alerts() -> void:
	if alerts == null:
		return
	if jobs.materials != null and jobs.food_kg_total() <= 0.0:
		alerts.set_alert("colony/no_food", AlertService.Severity.IMPORTANT, "No food left")
	else:
		alerts.clear("colony/no_food")
	var bedless := 0
	for n: Npc in _npcs.values():
		if n.bed_id.is_empty():
			bedless += 1
	if bedless > 0:
		alerts.set_alert("colony/no_free_bed", AlertService.Severity.GENERAL,
				"%d colonist(s) without a bed" % bedless)
	else:
		alerts.clear("colony/no_free_bed")


func _default_work() -> Dictionary:
	var we := {}
	for k: StringName in Npc.WORK_KEYS:
		we[k] = true
	return we


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
			# M4a
			"hunger": n.hunger,
			"stamina": n.stamina,
			"health": n.health,
			"condition": String(n.condition),
			"schedule": n.schedule.duplicate(),
			"bed_id": n.bed_id,
			"activity": String(n._activity),
			"phase": String(n._phase),
			"food_item": n._food_item,
			"eat_ticks": n._eat_ticks,
			"table_id": n._table_id,
			"in_bed": n._in_bed,
			"collapsed_since": n._collapsed_since,
		})
	var recent: Array = []
	for d: Dictionary in _recent_deaths:
		recent.append({"id": String(d["id"]), "nickname": String(d["nickname"]), "tile": d["tile"]})
	return {"npcs": list, "spawn_counter": _spawn_counter, "tick": _tick, "deaths": _deaths,
			"recent_deaths": recent}


## Restores NPCs (paths are recomputed). NPCs on tiles that are no longer
## standable are moved to the nearest standable tile. Load Colony before
## JobManager; JobManager.load_snapshot reconciles job links.
## Returns the number of dropped entries.
func load_snapshot(s: Dictionary) -> int:
	_npcs.clear()
	_full_names.clear()
	_nicknames.clear()
	_table_users.clear()
	_sleep_factor.clear()
	nav.invalidate_all()
	var dropped := 0
	var sc: Variant = s.get("spawn_counter", 0)
	var tk: Variant = s.get("tick", 0)
	var dc: Variant = s.get("deaths", 0)
	_spawn_counter = maxi(0, sc) if typeof(sc) == TYPE_INT else 0
	_tick = tk if typeof(tk) == TYPE_INT else 0
	_deaths = maxi(0, dc) if typeof(dc) == TYPE_INT else 0
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
			if not n._table_id.is_empty() and not _table_users.has(n._table_id):
				_table_users[n._table_id] = n.id
			else:
				n._table_id = ""
			if n._activity == &"sleep" and n._phase == &"asleep":
				_fall_asleep(n, n._in_bed)  # recompute the bed / bedroom factor
	_spawn_counter = maxi(_spawn_counter, _npcs.size())
	_recent_deaths.clear()
	var rd: Variant = s.get("recent_deaths", [])  # absent before the M4a fix round
	if typeof(rd) == TYPE_ARRAY:
		for e: Variant in rd:
			if typeof(e) == TYPE_DICTIONARY and typeof((e as Dictionary).get("id")) == TYPE_STRING \
					and typeof((e as Dictionary).get("nickname")) == TYPE_STRING \
					and typeof((e as Dictionary).get("tile")) == TYPE_VECTOR2I:
				_recent_deaths.append({"id": e["id"], "nickname": e["nickname"], "tile": e["tile"]})
			else:
				dropped += 1
		while _recent_deaths.size() > RECENT_DEATHS_KEPT:
			_recent_deaths.pop_front()
	refresh_alerts()  # alerts are not saved: show them right away, even paused
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
	n.work_enabled = _default_work()
	if typeof(we) == TYPE_DICTIONARY:
		for k: StringName in Npc.WORK_KEYS:
			var v: Variant = (we as Dictionary).get(String(k), true)
			n.work_enabled[k] = v if typeof(v) == TYPE_BOOL else true
	var ij: Variant = d.get("ignore_job_id", "")
	var iu: Variant = d.get("ignore_until", -1)
	n._ignore_job_id = ij if typeof(ij) == TYPE_STRING else ""
	n._ignore_until = iu if typeof(iu) == TYPE_INT else -1
	# M4a (older snapshots: fed, rested, healthy, default schedule).
	n.hunger = _num(d.get("hunger"), 100.0)
	n.stamina = _num(d.get("stamina"), 100.0)
	n.health = _num(d.get("health"), 100.0)
	var cond: Variant = d.get("condition", "ok")
	n.condition = StringName(cond) if typeof(cond) == TYPE_STRING \
			and StringName(cond) in [Npc.CONDITION_OK, Npc.CONDITION_COLLAPSED] else Npc.CONDITION_OK
	var sch: Variant = d.get("schedule")
	if typeof(sch) == TYPE_PACKED_BYTE_ARRAY and _check_schedule(sch).ok:
		n.schedule = (sch as PackedByteArray).duplicate()
	for k: String in ["bed_id", "food_item", "table_id"]:
		if typeof(d.get(k, "")) != TYPE_STRING:
			return null
	n.bed_id = d.get("bed_id", "")
	n._food_item = d.get("food_item", "")
	n._table_id = d.get("table_id", "")
	var act: Variant = d.get("activity", "")
	var ph: Variant = d.get("phase", "")
	n._activity = StringName(act) if typeof(act) == TYPE_STRING and StringName(act) in [&"", &"eat", &"sleep"] else &""
	n._phase = StringName(ph) if typeof(ph) == TYPE_STRING and n._activity != &"" else &""
	var et: Variant = d.get("eat_ticks", 0)
	n._eat_ticks = et if typeof(et) == TYPE_INT else 0
	var ib: Variant = d.get("in_bed", false)
	n._in_bed = ib if typeof(ib) == TYPE_BOOL else false
	var cs: Variant = d.get("collapsed_since", -1)
	n._collapsed_since = cs if typeof(cs) == TYPE_INT else -1
	if n.condition == Npc.CONDITION_COLLAPSED and n._collapsed_since < 0:
		n._collapsed_since = _tick
	if not n.is_ok():
		n._activity = &""
		n._phase = &""
	return n


static func _num(v: Variant, fallback: float) -> float:
	if typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT:
		return fallback
	var f := float(v)
	return clampf(f, 0.0, 100.0) if is_finite(f) else fallback


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
func _stand_groups_near(t: Vector2i, off_wall_orders: bool = false, avoid: Rect2i = Rect2i()) -> Array:
	var by_d := {}
	for dy in range(-MOVE_SEARCH_RADIUS, MOVE_SEARCH_RADIUS + 1):
		for dx in range(-MOVE_SEARCH_RADIUS, MOVE_SEARCH_RADIUS + 1):
			var d := absi(dx) + absi(dy)
			if d > MOVE_SEARCH_RADIUS:
				continue
			var p := t + Vector2i(dx, dy)
			if avoid.has_area() and Rect2i(p.x, p.y - (nav.clearance - 1), 1, nav.clearance).intersects(avoid):
				continue  # body would still cover the blocked site
			if nav.can_stand(p) and not (off_wall_orders and jobs.body_on_wall_order(p)):
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
