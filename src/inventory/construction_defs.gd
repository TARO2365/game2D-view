class_name ConstructionDefs
extends RefCounted
## Material recipes for construction orders (M2 contract §5).
## Keyed by DesignationMap.Kind values. The constants below mirror
## DesignationMap.Kind.BUILD_WALL (2) and BUILD_LADDER (3) so this file does
## not depend on DesignationMap already declaring BUILD_LADDER; a test keeps
## them in sync once it does.
## Material keys = TileDef.key of the dug tile (&"rock", &"dirt", ...).

const KIND_BUILD_WALL := 2    # == DesignationMap.Kind.BUILD_WALL
const KIND_BUILD_LADDER := 3  # == DesignationMap.Kind.BUILD_LADDER (contract §6)


## Returns {"materials": Array[StringName], "kg": float, "work_ticks": int},
## or {} for kinds that need no construction. Always a fresh copy.
static func recipe(kind: int) -> Dictionary:
	var mats: Array[StringName] = []
	match kind:
		KIND_BUILD_WALL:
			mats.append(&"rock")
			return {"materials": mats, "kg": 50.0, "work_ticks": 30}  # PLACEHOLDER
		KIND_BUILD_LADDER:
			mats.append(&"rock")
			mats.append(&"dirt")
			return {"materials": mats, "kg": 25.0, "work_ticks": 20}  # PLACEHOLDER
	return {}


## True if material can be used for kind's recipe.
static func accepts(kind: int, material: StringName) -> bool:
	var r := recipe(kind)
	return not r.is_empty() and material in r["materials"]
