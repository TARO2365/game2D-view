class_name Npc
extends RefCounted
## One colonist (M2 contract §7). Runtime instance owned and mutated by
## Colony (movement, intent) and JobManager (job link only). Other modules
## read the public fields. Fields starting with "_" are Colony internals.

const NO_TILE := Vector2i(-1, -1)
const WORK_KEYS: Array[StringName] = [&"dig", &"build", &"haul", &"farm", &"cook"]

## Schedule activity per hour (M4a contract §7). Stored in saves: never renumber.
enum Activity { WORK = 0, SLEEP = 1, FREE = 2 }
const CONDITION_OK := &"ok"
const CONDITION_COLLAPSED := &"collapsed"
const CONDITION_DEAD := &"dead"
const DEFAULT_WORK_START := 6   # 06-22 work, 22-06 sleep (D-028)
const DEFAULT_WORK_END := 22

## Stable id from StableIdAllocator category "npc" ("npc:3").
var id: String = ""
var full_name: String = ""
var nickname: String = ""
## Current feet tile (D-003: body = tile, tile-1, tile-2). While moving this
## is already the destination of the current step.
var tile: Vector2i = NO_TILE
## Tile the current step started from (== tile when not moving).
var prev_tile: Vector2i = NO_TILE
## 0..1 progress from prev_tile to tile (render interpolation).
var move_progress: float = 0.0
## &"idle" (no job), &"moving", &"working", &"carrying" (moving with an item),
## &"waiting" (holds a job but cannot progress right now: blocked site, no
## path budget, ...; Job.wait_reason / JobManager.describe_job say why),
## &"eating", &"sleeping", &"collapsed" (M4a).
var state: StringName = &"idle"
## Needs (M4a, 0..100): hunger 100 = full, stamina 100 = rested, health.
var hunger: float = 100.0
var stamina: float = 100.0
var health: float = 100.0
## CONDITION_OK / CONDITION_COLLAPSED / CONDITION_DEAD.
var condition: StringName = CONDITION_OK
## 24 bytes, one Activity per hour.
var schedule: PackedByteArray = default_schedule()
## Owned bed building id ("" = none yet; Colony auto-assigns).
var bed_id: String = ""
## Current job id, "" when none. Set only by JobManager.
var job_id: String = ""
## 0..1 progress of the current work step (dig / build).
var work_progress: float = 0.0
## Per-NPC work toggles (spec §3).
var work_enabled: Dictionary = {&"dig": true, &"build": true, &"haul": true, &"farm": true, &"cook": true}
## Standable tile of a player "Move here" command, NO_TILE when none.
var command_target: Vector2i = NO_TILE

# --- Colony internals (not part of the contract) -------------------------
## Remaining steps of the current path (excludes `tile`).
var _path: Array[Vector2i] = []
## True while a step from prev_tile to tile is in progress.
var _moving: bool = false
## Ticks the current step takes.
var _step_ticks: int = 1
## Job ignored after "Stop job" until _ignore_until (exclusive).
var _ignore_job_id: String = ""
var _ignore_until: int = -1
## No job assignment attempt before this tick (idle back-off).
var _next_assign_tick: int = 0
## Known complete reachable area (set by JobManager after an exhaustive failed
## path search, i.e. the NPC is confined, e.g. in a pit). Invalidated when
## terrain changes near it. Not saved.
var _region_valid: bool = false
var _region: Dictionary = {}        # standable feet tile index -> true
var _region_reach: Dictionary = {}  # tile index workable from the region -> true
var _region_bbox: Rect2i = Rect2i()
## Stockpile tiles (index -> true) this NPC failed to reach while delivering;
## cleared when terrain near the tile or near the NPC changes. Not saved.
var _blocked_drops: Dictionary = {}

# --- M4a need activities (Colony internals; saved) ---
## &"" (none), &"eat", &"sleep".
var _activity: StringName = &""
## eat: &"fetch", &"table", &"eating"; sleep: &"go", &"asleep".
var _phase: StringName = &""
## Food item reserved (ground / crate) or carried for eating.
var _food_item: String = ""
## Ticks left of the current eat step.
var _eat_ticks: int = 0
## Table building used for the current meal ("" = eating standing).
var _table_id: String = ""
## Asleep in a bed (else on the floor).
var _in_bed: bool = false
## Tick the NPC collapsed (-1 = not collapsed).
var _collapsed_since: int = -1
## No food search before this tick (no reachable food last time). Not saved.
var _food_retry_tick: int = 0
## Alert flags last published (key suffix -> true). Not saved (alerts are re-raised).
var _alert_flags: Dictionary = {}


static func default_schedule() -> PackedByteArray:
	var s := PackedByteArray()
	s.resize(24)
	for h in 24:
		s[h] = Activity.WORK if h >= DEFAULT_WORK_START and h < DEFAULT_WORK_END else Activity.SLEEP
	return s


func is_moving() -> bool:
	return _moving


func is_ok() -> bool:
	return condition == CONDITION_OK


func is_ignoring(job: String, tick: int) -> bool:
	return not job.is_empty() and job == _ignore_job_id and tick < _ignore_until


func _to_string() -> String:
	return "Npc(%s %s '%s' at %s %s job=%s)" % [id, full_name, nickname, tile, state, job_id]
