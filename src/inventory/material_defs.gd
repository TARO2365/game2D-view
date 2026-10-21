class_name MaterialDefs
extends Resource
## Table of material definitions (data/defs/materials.tres, M4a contract §4):
## every tile drop material plus food. Looked up by key; file order is the
## display order.

const DEFAULT_PATH := "res://data/defs/materials.tres"
const CATEGORY_FOOD := &"food"

@export var defs: Array[Resource] = []

var _by_key: Dictionary = {}  # StringName key -> MaterialDef


static func load_default() -> MaterialDefs:
	return load(DEFAULT_PATH) as MaterialDefs


## {key, display_name, color, category, nutrition_per_kg}, or {} if unknown.
func def(material: StringName) -> Dictionary:
	var d := get_def(material)
	return d.to_dict() if d != null else {}


func get_def(material: StringName) -> MaterialDef:
	if _by_key.is_empty():
		_index()
	return _by_key.get(material) as MaterialDef


func has(material: StringName) -> bool:
	return get_def(material) != null


## Keys in file order.
func all_keys() -> Array[StringName]:
	var out: Array[StringName] = []
	for d in _all():
		out.append(d.key)
	return out


## Food keys (category food) in file order.
func foods() -> Array[StringName]:
	var out: Array[StringName] = []
	for d in _all():
		if d.category == CATEGORY_FOOD:
			out.append(d.key)
	return out


func is_food(material: StringName) -> bool:
	var d := get_def(material)
	return d != null and d.category == CATEGORY_FOOD


## 0 for unknown or inedible materials.
func nutrition_per_kg(material: StringName) -> float:
	var d := get_def(material)
	return d.nutrition_per_kg if d != null else 0.0


func _all() -> Array[MaterialDef]:
	var out: Array[MaterialDef] = []
	for r in defs:
		var d := r as MaterialDef
		if d != null and not String(d.key).is_empty():
			out.append(d)
	return out


func _index() -> void:
	for d in _all():
		if not _by_key.has(d.key):
			_by_key[d.key] = d
