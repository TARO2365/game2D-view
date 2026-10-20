class_name BuildingRegistry
extends Resource
## Table of building definitions (data/defs/buildings.tres), looked up by key.

const DEFAULT_PATH := "res://data/defs/buildings.tres"

@export var defs: Array[Resource] = []

var _by_key: Dictionary = {}  # StringName key -> BuildingDef


static func load_default() -> BuildingRegistry:
	return load(DEFAULT_PATH) as BuildingRegistry


func get_def(key: StringName) -> BuildingDef:
	if _by_key.is_empty():
		_index()
	return _by_key.get(key) as BuildingDef


## Definitions in file order.
func all_defs() -> Array[BuildingDef]:
	var out: Array[BuildingDef] = []
	for r in defs:
		var d := r as BuildingDef
		if d:
			out.append(d)
	return out


func _index() -> void:
	for d in all_defs():
		_by_key[d.key] = d
