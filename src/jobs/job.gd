class_name Job
extends RefCounted
## One unit of NPC work (dig / build / haul). Runtime instance owned and
## mutated only by JobManager; other modules read it.
##
## Phases:
##   dig    open -> work -> done
##   build  open -> fetch -> deliver -> (fetch ...) -> work -> done
##          (wall: work -> clear -> work while stacks lie on the wall tile)
##   haul   open -> fetch -> deliver -> done
## `open` = no worker. Reservations held by a job: its worker (worker_id),
## at most one reserved ground item (item_id) and at most one item carried by
## its worker for it (carried_id). Haul jobs also hold a stockpile booking
## (stored in StockpileZones under the job id).

const KIND_DIG := &"dig"
const KIND_BUILD := &"build"
const KIND_HAUL := &"haul"
const KINDS: Array[StringName] = [KIND_DIG, KIND_BUILD, KIND_HAUL]

const PHASE_OPEN := &"open"
const PHASE_FETCH := &"fetch"
const PHASE_DELIVER := &"deliver"
const PHASE_WORK := &"work"
const PHASE_DONE := &"done"
## Wall build: carrying a stack that lay on the wall tile to a nearby spot.
const PHASE_CLEAR := &"clear"
const PHASES: Array[StringName] = [PHASE_OPEN, PHASE_FETCH, PHASE_DELIVER, PHASE_WORK, PHASE_DONE,
		PHASE_CLEAR]

## Stable id from StableIdAllocator category "job" ("job:7").
var id: String = ""
## KIND_DIG / KIND_BUILD / KIND_HAUL (also the Npc.work_enabled key).
var kind: StringName = KIND_DIG
## DesignationMap.Kind of the order (DIG / BUILD_WALL / BUILD_LADDER); NONE for haul.
var order_kind: int = 0
## Order tile (dig/build) or the source item's tile when created (haul).
var tile: Vector2i = Vector2i(-1, -1)
## 1..9, higher first.
var priority: int = 5
var worker_id: String = ""
var phase: StringName = PHASE_OPEN
## Reserved ground item (build: material to fetch; haul: stack to move).
var item_id: String = ""
## Item the worker carries for this job.
var carried_id: String = ""
## Work ticks done (dig/build work phase). Kept when the worker changes.
var work_ticks: int = 0
## Why an open job is not progressing ("no material", "blocked by NPC", ...).
var wait_reason: String = ""
## No NPC can reach it before this tick (-1 = reachable as far as we know).
var unreachable_until: int = -1

# JobManager internals (not saved).
## npc id -> tick until which that NPC does not retry this job (no path).
var _marks: Dictionary = {}
## unreachable_until was set because the order has no work position at all.
var _geo_unreachable: bool = false
## Listed in JobManager's open-job buckets, and under which priority.
var _open: bool = false
var _open_prio: int = 0
## Cached work positions.
var _goals: Array[Vector2i] = []
var _goals_version: int = -1
var _goals_key: Vector2i = Vector2i(-1, -1)
## Tile of the item the worker is walking to (fetch); a change = re-route.
var _fetch_tile: Vector2i = Vector2i(-1, -1)
## Ticks a wall build has waited for an NPC body to leave its tile.
var _blocked_ticks: int = 0


func is_done() -> bool:
	return phase == PHASE_DONE


func to_dict() -> Dictionary:
	return {
		"id": id,
		"kind": String(kind),
		"order_kind": order_kind,
		"tile": tile,
		"priority": priority,
		"worker_id": worker_id,
		"phase": String(phase),
		"item_id": item_id,
		"carried_id": carried_id,
		"work_ticks": work_ticks,
		"wait_reason": wait_reason,
	}


## Parses a snapshot entry; null if malformed (types only, no world checks).
static func from_dict(v: Variant) -> Job:
	if typeof(v) != TYPE_DICTIONARY:
		return null
	var d: Dictionary = v
	var j := Job.new()
	var id_v: Variant = d.get("id")
	if typeof(id_v) != TYPE_STRING or not StableIdAllocator.is_valid(id_v) \
			or StableIdAllocator.category_of(id_v) != &"job":
		return null
	j.id = id_v
	var kind_v: Variant = d.get("kind")
	if (typeof(kind_v) != TYPE_STRING and typeof(kind_v) != TYPE_STRING_NAME) \
			or not (StringName(kind_v) in KINDS):
		return null
	j.kind = StringName(kind_v)
	var phase_v: Variant = d.get("phase", "open")
	if (typeof(phase_v) != TYPE_STRING and typeof(phase_v) != TYPE_STRING_NAME) \
			or not (StringName(phase_v) in PHASES):
		return null
	j.phase = StringName(phase_v)
	var tile_v: Variant = d.get("tile")
	if typeof(tile_v) != TYPE_VECTOR2I:
		return null
	j.tile = tile_v
	for key: String in ["order_kind", "priority", "work_ticks"]:
		if typeof(d.get(key, 0)) != TYPE_INT:
			return null
	j.order_kind = d.get("order_kind", 0)
	j.priority = clampi(d.get("priority", 5), 1, 9)
	j.work_ticks = maxi(0, d.get("work_ticks", 0))
	for key: String in ["worker_id", "item_id", "carried_id", "wait_reason"]:
		if typeof(d.get(key, "")) != TYPE_STRING:
			return null
	j.worker_id = d.get("worker_id", "")
	j.item_id = d.get("item_id", "")
	j.carried_id = d.get("carried_id", "")
	j.wait_reason = d.get("wait_reason", "")
	return j
