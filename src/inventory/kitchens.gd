class_name Kitchens
extends RefCounted
## Kitchen production (M4a contract §5): one recipe, a per-kitchen meal
## target, and the cook step. Cooking uses the M3 site flow: JobManager hauls
## RECIPE.input_kg of RECIPE.input to SITE(job_id), works RECIPE.work_ticks,
## then calls cook(), which consumes exactly input_kg from that site and
## spawns the output on drop_tile. Conservation: the input is counted as
## consumed and the output as spawned (Inventory ledgers).
##
## kitchens_changed(building_id) (not in the contract, for UI) fires when a
## kitchen appears/disappears or its target changes; "" = everything (load).
##
## NOTE (Systems Agent): the buildings provider is duck-typed (see
## BuildingTracker) so this module does not depend on src/world.

signal kitchens_changed(building_id: String)

const BUILDING_KEY := &"kitchen"
const RECIPE := {"input": &"mushroom", "input_kg": 2.0, "output": &"meal", "output_kg": 2.0,
		"work_ticks": 60}   # PLACEHOLDER values
const DEFAULT_TARGET_KG := 10.0   # PLACEHOLDER
const MAX_TARGET_KG := 10000.0    # PLACEHOLDER (UI slider bound)

var inventory: Inventory

var _tracker: BuildingTracker
var _targets: Dictionary = {}   # building id -> float (only values != DEFAULT_TARGET_KG)


func _init(buildings: RefCounted, inv: Inventory) -> void:
	inventory = inv
	_tracker = BuildingTracker.new(buildings, BUILDING_KEY)
	_tracker.added.connect(_on_added)
	_tracker.removed.connect(_on_removed)


# --- Queries ------------------------------------------------------------

## kitchen building ids, ordered by id number.
func kitchen_ids() -> Array[String]:
	return _tracker.ids()


func is_kitchen(building_id: String) -> bool:
	return _tracker.has(building_id)


## Meal kg this kitchen keeps in storage colony-wide; 0 for non-kitchens.
func target_kg(building_id: String) -> float:
	if not _tracker.has(building_id):
		return 0.0
	return float(_targets.get(building_id, DEFAULT_TARGET_KG))


## True when building_id is a kitchen and total_meal_kg (stored meal counted
## by the caller) is below its target.
func needs_cooking(total_meal_kg: float, building_id: String) -> bool:
	if not is_finite(total_meal_kg):
		return false
	return total_meal_kg < target_kg(building_id) - Inventory.KG_EPSILON


# --- Commands -----------------------------------------------------------

## 0 = never cook here. Valid range 0..MAX_TARGET_KG.
func set_target_kg(building_id: String, kg: float) -> CommandResult:
	if not _tracker.has(building_id):
		return CommandResult.failure(&"not_kitchen", "%s is not a kitchen" % building_id)
	if not is_finite(kg) or kg < 0.0 or kg > MAX_TARGET_KG:
		return CommandResult.failure(&"invalid_kg", "Target must be 0..%d kg" % int(MAX_TARGET_KG))
	if kg == DEFAULT_TARGET_KG:
		_targets.erase(building_id)
	else:
		_targets[building_id] = kg
	kitchens_changed.emit(building_id)
	return CommandResult.success({"building_id": building_id, "kg": kg})


## Consumes RECIPE.input_kg of RECIPE.input from SITE(job_id) and spawns
## RECIPE.output_kg of RECIPE.output on drop_tile. data: {item_id, kg,
## material, consumed_kg}. Fails (nothing changes) with not_kitchen,
## invalid_job or missing_input (data["available_kg"]).
func cook(building_id: String, job_id: String, drop_tile: Vector2i) -> CommandResult:
	if not _tracker.has(building_id):
		return CommandResult.failure(&"not_kitchen", "%s is not a kitchen" % building_id)
	if job_id.is_empty():
		return CommandResult.failure(&"invalid_job", "No job given")
	var r := inventory.consume_from_site(job_id, RECIPE["input"], RECIPE["input_kg"])
	if not r.ok:
		return r
	var out: StringName = RECIPE["output"]
	var kg: float = RECIPE["output_kg"]
	var item_id := inventory.spawn_ground(out, kg, drop_tile)
	return CommandResult.success({"item_id": item_id, "kg": kg, "material": out,
			"consumed_kg": r.data["kg"]})


# --- Persistence --------------------------------------------------------

## Plain-typed; only targets that differ from the default are listed.
func to_snapshot() -> Dictionary:
	var ids := _targets.keys()
	ids.sort_custom(BuildingTracker._less_id)
	var targets: Array = []
	for id: String in ids:
		targets.append({"building_id": id, "kg": float(_targets[id])})
	return {"targets": targets}


## Load after Buildings. Drops entries for non-kitchens, duplicates and kg
## outside 0..MAX_TARGET_KG. Returns the number of dropped entries.
func load_snapshot(s: Dictionary) -> int:
	_tracker.refresh(false)
	_targets.clear()
	var dropped := 0
	var t_v: Variant = s.get("targets")
	if typeof(t_v) == TYPE_ARRAY:
		for e: Variant in t_v:
			if not _load_target(e):
				dropped += 1
	kitchens_changed.emit("")
	return dropped


func _load_target(e: Variant) -> bool:
	if typeof(e) != TYPE_DICTIONARY:
		return false
	var d: Dictionary = e
	var id: Variant = d.get("building_id")
	var kg: Variant = d.get("kg")
	if typeof(id) != TYPE_STRING or not _tracker.has(id) or _targets.has(id):
		return false
	if typeof(kg) != TYPE_FLOAT and typeof(kg) != TYPE_INT:
		return false
	var v := float(kg)
	if not is_finite(v) or v < 0.0 or v > MAX_TARGET_KG:
		return false
	if v != DEFAULT_TARGET_KG:
		_targets[String(id)] = v
	return true


# --- Internals ----------------------------------------------------------

func _on_added(id: String) -> void:
	kitchens_changed.emit(id)


func _on_removed(id: String) -> void:
	_targets.erase(id)
	kitchens_changed.emit(id)
