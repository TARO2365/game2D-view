extends RefCounted
## Minimal stand-in for Buildings (src/world/buildings.gd) used by Systems
## tests: only the members the inventory modules use (all_ids, get_building,
## def(key).storage_kg, count, signals). Like Buildings, remove/lose emit
## buildings_changed before building_lost; load_silently emits nothing
## (Buildings.load_snapshot is silent).

signal buildings_changed(rect: Rect2i)
signal building_lost(id: String, key: StringName, origin: Vector2i, materials: Dictionary)


class Def extends Resource:
	var key: StringName
	var storage_kg: float = 0.0

	func _init(k: StringName = &"", kg: float = 0.0) -> void:
		key = k
		storage_kg = kg


var defs: Dictionary = {
	&"farm_plot": Def.new(&"farm_plot"),
	&"kitchen": Def.new(&"kitchen"),
	&"crate": Def.new(&"crate", 2000.0),
	&"bed": Def.new(&"bed"),
}
var placed: Dictionary = {}   # id -> {id, key, origin, materials}
var next_num := 1


func def(key: StringName) -> Def:
	return defs.get(key)


func get_building(id: String) -> Dictionary:
	var b: Variant = placed.get(id)
	return (b as Dictionary).duplicate() if b != null else {}


func all_ids() -> Array[String]:
	var out: Array[String] = []
	for id: String in placed:
		out.append(id)
	return out


func count() -> int:
	return placed.size()


func place(key: StringName, origin: Vector2i) -> String:
	var id := "bld:%d" % next_num
	next_num += 1
	placed[id] = {"id": id, "key": key, "origin": origin, "materials": {&"rock": 50.0}}
	buildings_changed.emit(Rect2i(origin, Vector2i.ONE))
	return id


func remove(id: String) -> void:
	var b: Dictionary = placed[id]
	placed.erase(id)
	buildings_changed.emit(Rect2i(b["origin"], Vector2i.ONE))


func lose(id: String) -> void:
	var b: Dictionary = placed[id]
	placed.erase(id)
	buildings_changed.emit(Rect2i(b["origin"], Vector2i.ONE))
	building_lost.emit(id, b["key"], b["origin"], b["materials"])


func load_silently(entries: Dictionary) -> void:
	placed = entries.duplicate(true)
