class_name BuildingTracker
extends RefCounted
## Cached, id-sorted set of the placed buildings with one definition key
## (Farming: &"farm_plot", Kitchens: &"kitchen"). Follows the Buildings
## provider through its signals; Buildings.load_snapshot emits nothing, so a
## changed provider count() also refreshes the cache, and owners call
## refresh() from their own load_snapshot (save load order: buildings first).
##
## The provider is duck-typed (same pattern as CrateStorage): only all_ids(),
## get_building(id), count() (optional) and the signals buildings_changed /
## building_lost are used, so tests can pass a fake.

## Emitted for every tracked building that appears / disappears, in id order.
## refresh(false) (loading) does not emit.
signal added(building_id: String)
signal removed(building_id: String)

var key: StringName

var _provider: RefCounted
var _ok: bool = false
var _list: Array[String] = []     # sorted by id number
var _origins: Dictionary = {}     # id -> Vector2i
var _seen_count: int = -1
var _has_count: bool = false


func _init(provider: RefCounted, building_key: StringName) -> void:
	_provider = provider
	key = building_key
	_has_count = _provider.has_method(&"count")
	_provider.connect(&"buildings_changed", _on_buildings_changed)
	_provider.connect(&"building_lost", _on_building_lost)
	refresh(false)


func ids() -> Array[String]:
	_ensure()
	return _list.duplicate()


func has(building_id: String) -> bool:
	_ensure()
	return _origins.has(building_id)


## Origin tile of a tracked building, Vector2i(-1, -1) if not tracked.
func origin(building_id: String) -> Vector2i:
	_ensure()
	return _origins.get(building_id, Vector2i(-1, -1))


## Re-reads the provider; with emit_signals, reports what appeared/vanished.
func refresh(emit_signals: bool = true) -> void:
	var before := _list.duplicate()
	_list.clear()
	_origins.clear()
	var all: Array = _provider.call(&"all_ids")
	for v: Variant in all:
		var id := String(v)
		var b: Dictionary = _provider.call(&"get_building", id)
		if b.is_empty() or StringName(b.get("key", &"")) != key:
			continue
		var o: Variant = b.get("origin", Vector2i.ZERO)
		_list.append(id)
		_origins[id] = o if typeof(o) == TYPE_VECTOR2I else Vector2i.ZERO
	_list.sort_custom(_less_id)
	_seen_count = int(_provider.call(&"count")) if _has_count else -1
	_ok = true
	if not emit_signals:
		return
	for id: String in before:
		if not _origins.has(id):
			removed.emit(id)
	for id in _list:
		if not before.has(id):
			added.emit(id)


func _ensure() -> void:
	if _ok and (not _has_count or int(_provider.call(&"count")) == _seen_count):
		return
	refresh(true)


func _on_buildings_changed(_rect: Rect2i) -> void:
	refresh(true)


func _on_building_lost(_id: String, _key: StringName, _origin: Vector2i, _materials: Dictionary) -> void:
	# Buildings removes the building (emitting buildings_changed) before it
	# emits building_lost, so this normally finds nothing new.
	refresh(true)


static func _id_num(id: String) -> int:
	return int(id.substr(id.rfind(StableIdAllocator.SEPARATOR) + 1))


static func _less_id(a: String, b: String) -> bool:
	var na := _id_num(a)
	var nb := _id_num(b)
	return na < nb if na != nb else a < b
