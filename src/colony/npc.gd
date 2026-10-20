class_name Npc
extends RefCounted
## One colonist (M2 contract §7). Runtime instance owned and mutated by
## Colony (movement, intent) and JobManager (job link only). Other modules
## read the public fields. Fields starting with "_" are Colony internals.

const NO_TILE := Vector2i(-1, -1)
const WORK_KEYS: Array[StringName] = [&"dig", &"build", &"haul"]

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
## &"idle", &"moving", &"working", &"carrying" (moving with an item).
var state: StringName = &"idle"
## Current job id, "" when none. Set only by JobManager.
var job_id: String = ""
## 0..1 progress of the current work step (dig / build).
var work_progress: float = 0.0
## Per-NPC work toggles (spec §3).
var work_enabled: Dictionary = {&"dig": true, &"build": true, &"haul": true}
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


func is_moving() -> bool:
	return _moving


func is_ignoring(job: String, tick: int) -> bool:
	return not job.is_empty() and job == _ignore_job_id and tick < _ignore_until


func _to_string() -> String:
	return "Npc(%s %s '%s' at %s %s job=%s)" % [id, full_name, nickname, tile, state, job_id]
