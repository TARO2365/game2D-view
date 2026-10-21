class_name Farming
extends RefCounted
## Crop state, one crop per farm_plot building (M4a contract §5).
## EMPTY --plant()--> GROWING --update() x GROW_TICKS--> READY --harvest()--> EMPTY.
## JobManager decides who plants/harvests and when; Farming only keeps the
## state and spawns the harvest through Inventory.spawn_ground.
## Farms appear/disappear with farm_plot buildings (also building_lost); a
## removed farm loses its crop (nothing is refunded for an unripe crop).
##
## farms_changed(building_id) fires when a farm appears or disappears and on
## every stage change (not on each growth tick); "" = everything (load).
##
## NOTE (Systems Agent): the buildings provider is duck-typed (see
## BuildingTracker) so this module does not depend on src/world.

signal farms_changed(building_id: String)

enum Stage { EMPTY = 0, GROWING = 1, READY = 2 }

const BUILDING_KEY := &"farm_plot"
const CROP_MATERIAL := &"mushroom"
const GROW_TICKS := 6000   # PLACEHOLDER: one day (GameTime.TICKS_PER_DAY)
const YIELD_KG := 6.0      # PLACEHOLDER: mushroom kg per harvest
## stage() of an id that is not a farm_plot.
const NO_FARM := -1

var inventory: Inventory

var _tracker: BuildingTracker
var _ids: StableIdAllocator      # contract signature; items get ids from Inventory
var _crops: Dictionary = {}      # building id -> {"stage": int, "growth": int} (EMPTY farms absent)
var _last_tick: int = -1         # not saved: the first update after a load grows 1 tick


func _init(buildings: RefCounted, inv: Inventory, ids: StableIdAllocator = null) -> void:
	inventory = inv
	_ids = ids
	_tracker = BuildingTracker.new(buildings, BUILDING_KEY)
	_tracker.added.connect(_on_added)
	_tracker.removed.connect(_on_removed)


# --- Queries ------------------------------------------------------------

## farm_plot building ids, ordered by id number.
func farm_ids() -> Array[String]:
	return _tracker.ids()


func is_farm(building_id: String) -> bool:
	return _tracker.has(building_id)


## Stage value, or NO_FARM for ids that are not farm plots.
func stage(building_id: String) -> int:
	if not _tracker.has(building_id):
		return NO_FARM
	var c: Variant = _crops.get(building_id)
	return int(c["stage"]) if c != null else Stage.EMPTY


## 0..1 (EMPTY and non-farms 0, READY 1).
func progress(building_id: String) -> float:
	match stage(building_id):
		Stage.GROWING:
			return clampf(float(_crops[building_id]["growth"]) / GROW_TICKS, 0.0, 1.0)
		Stage.READY:
			return 1.0
	return 0.0


# --- Commands -----------------------------------------------------------

## EMPTY -> GROWING (JobManager calls it when the farmer finishes planting).
func plant(building_id: String) -> CommandResult:
	var s := stage(building_id)
	if s == NO_FARM:
		return CommandResult.failure(&"not_farm", "%s is not a farm plot" % building_id)
	if s != Stage.EMPTY:
		return CommandResult.failure(&"not_empty", "The farm plot is already planted")
	_crops[building_id] = {"stage": Stage.GROWING, "growth": 0}
	farms_changed.emit(building_id)
	return CommandResult.success({"building_id": building_id})


## READY -> EMPTY; spawns YIELD_KG of CROP_MATERIAL on drop_tile (data["item_id"]).
func harvest(building_id: String, drop_tile: Vector2i) -> CommandResult:
	var s := stage(building_id)
	if s == NO_FARM:
		return CommandResult.failure(&"not_farm", "%s is not a farm plot" % building_id)
	if s != Stage.READY:
		return CommandResult.failure(&"not_ready", "Nothing to harvest yet",
				{"progress": progress(building_id)})
	var item_id := inventory.spawn_ground(CROP_MATERIAL, YIELD_KG, drop_tile)
	_crops.erase(building_id)
	farms_changed.emit(building_id)
	return CommandResult.success({"item_id": item_id, "kg": YIELD_KG, "material": CROP_MATERIAL})


## Grows every GROWING crop by the ticks elapsed since the previous call
## (1 on the first call, 0 if the tick did not advance, at most GROW_TICKS).
func update(tick: int) -> void:
	var delta := 1 if _last_tick < 0 else clampi(tick - _last_tick, 0, GROW_TICKS)
	_last_tick = tick
	if delta == 0 or _crops.is_empty():
		return
	var ids := _crops.keys()
	ids.sort_custom(BuildingTracker._less_id)
	for id: String in ids:
		if not _tracker.has(id):
			_crops.erase(id)  # farm vanished without a signal (defensive)
			continue
		var c: Dictionary = _crops[id]
		if int(c["stage"]) != Stage.GROWING:
			continue
		c["growth"] = int(c["growth"]) + delta
		if int(c["growth"]) >= GROW_TICKS:
			c["growth"] = GROW_TICKS
			c["stage"] = Stage.READY
			farms_changed.emit(id)


# --- Persistence --------------------------------------------------------

## Plain-typed; EMPTY farms are not listed.
func to_snapshot() -> Dictionary:
	var ids := _crops.keys()
	ids.sort_custom(BuildingTracker._less_id)
	var farms: Array = []
	for id: String in ids:
		farms.append({"building_id": id, "stage": int(_crops[id]["stage"]),
				"growth": int(_crops[id]["growth"])})
	return {"farms": farms}


## Load after Buildings. Drops entries for non-farm ids, duplicates, bad
## stages and growth outside 0..GROW_TICKS; a GROWING crop saved fully grown
## loads as READY. Returns the number of dropped entries.
func load_snapshot(s: Dictionary) -> int:
	_tracker.refresh(false)
	_crops.clear()
	_last_tick = -1
	var dropped := 0
	var f_v: Variant = s.get("farms")
	if typeof(f_v) == TYPE_ARRAY:
		for e: Variant in f_v:
			if not _load_farm(e):
				dropped += 1
	farms_changed.emit("")
	return dropped


func _load_farm(e: Variant) -> bool:
	if typeof(e) != TYPE_DICTIONARY:
		return false
	var d: Dictionary = e
	var id: Variant = d.get("building_id")
	var st: Variant = d.get("stage")
	var gr: Variant = d.get("growth")
	if typeof(id) != TYPE_STRING or not _tracker.has(id) or _crops.has(id):
		return false
	if typeof(st) != TYPE_INT or not (st in [Stage.GROWING, Stage.READY]):
		return false
	if typeof(gr) != TYPE_INT or gr < 0 or gr > GROW_TICKS:
		return false
	var stage_v: int = st
	var growth: int = gr
	if stage_v == Stage.READY or growth >= GROW_TICKS:
		stage_v = Stage.READY
		growth = GROW_TICKS
	_crops[String(id)] = {"stage": stage_v, "growth": growth}
	return true


# --- Internals ----------------------------------------------------------

func _on_added(id: String) -> void:
	farms_changed.emit(id)


func _on_removed(id: String) -> void:
	_crops.erase(id)
	farms_changed.emit(id)
