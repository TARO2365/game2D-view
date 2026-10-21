class_name BuildingDef
extends Resource
## Static definition of one building type (M3 contract §2). Definition only;
## placed instances live in `Buildings`. `key` is written into save files:
## NEVER rename or reuse a key.

@export var key: StringName = &""
@export var display_name: String = ""
## Footprint in tiles. Origin = bottom-left tile; the footprint extends up
## and to the right.
@export var size: Vector2i = Vector2i.ONE
## Accepted build materials (any one; material = tile key, e.g. &"rock").
@export var materials: Array[StringName] = []
## Material mass needed to build. PLACEHOLDER.
@export var kg: float = 0.0
## Build work in simulation ticks. PLACEHOLDER.
@export var work_ticks: int = 0
## Every tile under the bottom row must be solid.
@export var needs_floor: bool = true
## Tile keys the floor must be made of (M4a: farm plot needs dirt or rock).
## Empty = any solid tile. Only checked when needs_floor.
@export var floor_materials: Array[StringName] = []
## Passable, but a room boundary. Must stand in a 1-wide wall gap: solid tile
## directly above the top tile (and a floor when needs_floor).
@export var is_door: bool = false
## > 0 = storage crate capacity in kg. PLACEHOLDER.
@export var storage_kg: float = 0.0
## Room classification tag: &"bedroom", &"storage", &"dining" or &"".
@export var room_tag: StringName = &""


func accepts_material(material: StringName) -> bool:
	return materials.has(material)
