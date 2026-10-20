class_name TileRegistry
extends Resource
## Table of tile definitions. The constants below mirror the ids stored in
## data/defs/tile_defs.tres and in save files: never renumber or reuse.

const AIR := 0
const DIRT := 1
const ROCK := 2
const IRON_ORE := 3
const GOLD_ORE := 4
const CRYSTAL := 5
const BEDROCK := 6
const CONCRETE := 7

const DEFAULT_PATH := "res://data/defs/tile_defs.tres"

@export var defs: Array[Resource] = []

var _by_id: Dictionary = {}  # int -> TileDef


static func load_default() -> TileRegistry:
	return load(DEFAULT_PATH) as TileRegistry


func get_def(id: int) -> TileDef:
	if _by_id.is_empty():
		_index()
	return _by_id.get(id) as TileDef


func all_defs() -> Array[TileDef]:
	if _by_id.is_empty():
		_index()
	var out: Array[TileDef] = []
	for id in _by_id:
		out.append(_by_id[id])
	return out


func max_id() -> int:
	var m := 0
	for d in all_defs():
		m = maxi(m, d.id)
	return m


func is_solid(id: int) -> bool:
	var d := get_def(id)
	return d != null and d.solid


func is_diggable(id: int) -> bool:
	var d := get_def(id)
	return d != null and d.solid and d.diggable


func _index() -> void:
	for r in defs:
		var d := r as TileDef
		if d:
			_by_id[d.id] = d
