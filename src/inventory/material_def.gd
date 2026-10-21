class_name MaterialDef
extends Resource
## One material that items can be made of (M4a contract §4). Definition only;
## items reference it by key. Keys are saved in item snapshots: never rename.

@export var key: StringName = &""
@export var display_name: String = ""
## Placeholder colour (item piles, UI swatches) until real art exists.
@export var color: Color = Color.WHITE
## &"soil", &"ore" or &"food".
@export var category: StringName = &"soil"
## Hunger points restored per kg eaten (0 = not edible). PLACEHOLDER.
@export var nutrition_per_kg: float = 0.0


func to_dict() -> Dictionary:
	return {"key": key, "display_name": display_name, "color": color, "category": category,
			"nutrition_per_kg": nutrition_per_kg}
