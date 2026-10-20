class_name TileDef
extends Resource
## Static definition of one tile type (definition, not runtime instance).
## `id` is written into save files: NEVER renumber or reuse an id.

@export var id: int = 0
@export var key: StringName = &""
@export var display_name: String = ""
## Flat color for runtime-generated placeholder art (not final art).
@export var placeholder_color: Color = Color.MAGENTA
@export var solid: bool = true
## Can a dig order target this tile?
@export var diggable: bool = true
## Relative dig effort for M2 jobs. PLACEHOLDER.
@export var hardness: float = 1.0
## Draw lighter speckles (ores) in placeholder art.
@export var placeholder_speckle_light: bool = false
## Mass of the material item spawned when this tile is dug (material = `key`).
## 0 = drops nothing. PLACEHOLDER: dirt/rock/ores 50 kg (M2 contract §2).
@export var drop_kg: float = 0.0
