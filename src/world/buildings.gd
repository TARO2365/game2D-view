class_name Buildings
extends RefCounted
## Placed building instances and their tile occupancy (M3 contract §2).
## Buildings sit in air tiles and never block movement (furniture is
## walk-through, doors are passable). This class is the only owner of
## building instances; the grid asks it which tiles are occupied
## (WorldGrid.set_building_query) so walls/ladders cannot be built on them.
##
## Every place/remove emits `buildings_changed(footprint)` and makes the grid
## emit `tiles_changed(footprint)` so navigation, rooms and designations
## refresh. After any `tiles_changed`, a building whose floor (or a door's top
## support) is gone is removed and `building_lost` is emitted with the
## materials it was built from (JobManager drops them, D-021).

signal buildings_changed(rect: Rect2i)
signal building_lost(id: String, key: StringName, origin: Vector2i, materials: Dictionary)

const ID_CATEGORY := &"bld"

var grid: WorldGrid
var registry: BuildingRegistry
var _ids: StableIdAllocator
## id -> {"key": StringName, "origin": Vector2i, "materials": Dictionary(StringName -> float)}
var _by_id: Dictionary = {}
var _occupancy: Dictionary = {}  # tile index -> building id


func _init(world_grid: WorldGrid, ids: StableIdAllocator, defs: BuildingRegistry = null) -> void:
	grid = world_grid
	_ids = ids
	registry = defs if defs != null else BuildingRegistry.load_default()
	grid.set_building_query(_has_building_at)
	grid.tiles_changed.connect(_on_tiles_changed)


func def(key: StringName) -> BuildingDef:
	return registry.get_def(key)


## Footprint rect: origin is the bottom-left tile, so the rect grows upwards.
## Unknown key -> empty rect.
func footprint(key: StringName, origin: Vector2i) -> Rect2i:
	var d := def(key)
	if d == null:
		return Rect2i()
	return Rect2i(origin.x, origin.y - d.size.y + 1, d.size.x, d.size.y)


## Failure codes: unknown_key, out_of_bounds, blocked (tile not air, ladder or
## building there), no_floor (a tile under the bottom row is not solid),
## no_support (door: tile above the top is not solid).
func can_place(key: StringName, origin: Vector2i) -> CommandResult:
	var d := def(key)
	if d == null:
		return CommandResult.failure(&"unknown_key", "Unknown building '%s'" % key)
	var r := footprint(key, origin)
	if not grid.bounds().encloses(r):
		return CommandResult.failure(&"out_of_bounds", "The building does not fit inside the world")
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var i := y * grid.width + x
			if grid.tiles[i] != TileRegistry.AIR or grid.structures[i] != WorldGrid.Structure.NONE \
					or _occupancy.has(i):
				return CommandResult.failure(&"blocked", "%s needs open, empty tiles" % d.display_name,
						{"tile": Vector2i(x, y)})
	if not _has_support(d, r):
		if d.needs_floor and not _has_floor(r):
			return CommandResult.failure(&"no_floor", "%s needs solid floor under it" % d.display_name)
		return CommandResult.failure(&"no_support",
				"%s must stand in a wall gap (solid tile above it)" % d.display_name)
	return CommandResult.success({"rect": r})


## `materials`: material -> kg used to build it (returned by remove/building_lost).
## Every material must be accepted by the definition and kg > 0.
func place(key: StringName, origin: Vector2i, materials: Dictionary) -> CommandResult:
	var check := can_place(key, origin)
	if not check.ok:
		return check
	var d := def(key)
	var mats := {}
	for m in materials:
		var kg_v: Variant = materials[m]
		var material := StringName(str(m))
		if not (typeof(kg_v) in [TYPE_FLOAT, TYPE_INT]) or float(kg_v) <= 0.0 \
				or not d.accepts_material(material):
			return CommandResult.failure(&"invalid_materials",
					"%s cannot be built from %s" % [d.display_name, m])
		mats[material] = float(mats.get(material, 0.0)) + float(kg_v)
	var id := _ids.allocate(ID_CATEGORY)
	_add(id, key, origin, mats)
	var r := footprint(key, origin)
	_announce(r)
	return CommandResult.success({"id": id, "rect": r})


## data: {"materials": material -> kg, "key", "origin", "rect"}.
func remove(id: String) -> CommandResult:
	if not _by_id.has(id):
		return CommandResult.failure(&"unknown_building", "No such building")
	var b: Dictionary = _by_id[id]
	var r := footprint(b["key"], b["origin"])
	_erase(id)
	_announce(r)
	return CommandResult.success({"materials": (b["materials"] as Dictionary).duplicate(),
			"key": b["key"], "origin": b["origin"], "rect": r})


## {id, key, origin, materials} or {} when unknown.
func get_building(id: String) -> Dictionary:
	if not _by_id.has(id):
		return {}
	var b: Dictionary = _by_id[id]
	return {"id": id, "key": b["key"], "origin": b["origin"],
			"materials": (b["materials"] as Dictionary).duplicate()}


func building_at(tile: Vector2i) -> String:
	if not grid.in_bounds(tile):
		return ""
	return _occupancy.get(tile.y * grid.width + tile.x, "")


## Sorted by id number (creation order).
func all_ids() -> Array[String]:
	var out: Array[String] = []
	for id in _by_id:
		out.append(id)
	out.sort_custom(func(a: String, b: String) -> bool: return _id_num(a) < _id_num(b))
	return out


func count() -> int:
	return _by_id.size()


func is_door(tile: Vector2i) -> bool:
	var id := building_at(tile)
	if id.is_empty():
		return false
	var d := def(_by_id[id]["key"])
	return d != null and d.is_door


## Room tag of the building on `tile` (&"" if none).
func room_tag_at(tile: Vector2i) -> StringName:
	var id := building_at(tile)
	if id.is_empty():
		return &""
	var d := def(_by_id[id]["key"])
	return d.room_tag if d != null else &""


# --- Snapshot -----------------------------------------------------------

## Plain types only (survives var_to_bytes): {"buildings": [{id, key, x, y, materials}]}.
func to_snapshot() -> Dictionary:
	var list: Array = []
	for id in all_ids():
		var b: Dictionary = _by_id[id]
		var mats := {}
		for m in b["materials"]:
			mats[String(m)] = float(b["materials"][m])
		var o: Vector2i = b["origin"]
		list.append({"id": id, "key": String(b["key"]), "x": o.x, "y": o.y, "materials": mats})
	return {"buildings": list}


## Load after the grid. Emits no signals (rooms/navigation are rebuilt by the
## session). Invalid entries (bad id/duplicate, unknown key, junk types, can
## no longer be placed) are dropped; returns the number dropped.
func load_snapshot(s: Dictionary) -> int:
	_by_id.clear()
	_occupancy.clear()
	var list_v: Variant = s.get("buildings")
	if typeof(list_v) != TYPE_ARRAY:
		return 0
	var dropped := 0
	for e: Variant in list_v:
		if not _load_entry(e):
			dropped += 1
	return dropped


func _load_entry(e: Variant) -> bool:
	if typeof(e) != TYPE_DICTIONARY:
		return false
	var d: Dictionary = e
	var id_v: Variant = d.get("id")
	var key_v: Variant = d.get("key")
	var x_v: Variant = d.get("x")
	var y_v: Variant = d.get("y")
	var mats_v: Variant = d.get("materials", {})
	if typeof(id_v) != TYPE_STRING or not (typeof(key_v) in [TYPE_STRING, TYPE_STRING_NAME]) \
			or typeof(x_v) != TYPE_INT or typeof(y_v) != TYPE_INT or typeof(mats_v) != TYPE_DICTIONARY:
		return false
	var id: String = id_v
	if not StableIdAllocator.is_valid(id) or StableIdAllocator.category_of(id) != ID_CATEGORY \
			or _by_id.has(id):
		return false
	var key := StringName(key_v)
	var origin := Vector2i(x_v, y_v)
	if not can_place(key, origin).ok:
		return false
	var bdef := def(key)
	var mats := {}
	for m: Variant in mats_v:
		var kg_v: Variant = (mats_v as Dictionary)[m]
		if not (typeof(m) in [TYPE_STRING, TYPE_STRING_NAME]) or not (typeof(kg_v) in [TYPE_FLOAT, TYPE_INT]):
			continue
		var material := StringName(m)
		if float(kg_v) > 0.0 and bdef.accepts_material(material):
			mats[material] = float(kg_v)
	_add(id, key, origin, mats)
	return true


# --- Internals ----------------------------------------------------------

func _add(id: String, key: StringName, origin: Vector2i, mats: Dictionary) -> void:
	_by_id[id] = {"key": key, "origin": origin, "materials": mats}
	var r := footprint(key, origin)
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			_occupancy[y * grid.width + x] = id


func _erase(id: String) -> void:
	var b: Dictionary = _by_id[id]
	var r := footprint(b["key"], b["origin"])
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			_occupancy.erase(y * grid.width + x)
	_by_id.erase(id)


func _announce(r: Rect2i) -> void:
	grid.notify_changed(r)
	buildings_changed.emit(r)


func _has_building_at(p: Vector2i) -> bool:
	return grid.in_bounds(p) and _occupancy.has(p.y * grid.width + p.x)


func _has_floor(r: Rect2i) -> bool:
	for x in range(r.position.x, r.end.x):
		if not grid.is_solid_at(Vector2i(x, r.end.y)):
			return false
	return true


func _has_support(d: BuildingDef, r: Rect2i) -> bool:
	if d.needs_floor and not _has_floor(r):
		return false
	if d.is_door:
		for x in range(r.position.x, r.end.x):
			if not grid.is_solid_at(Vector2i(x, r.position.y - 1)):
				return false
	return true


## Removes buildings whose support disappeared in or next to `rect`.
func _on_tiles_changed(rect: Rect2i) -> void:
	if _by_id.is_empty():
		return
	var lost: Array[String] = []
	for id: String in _by_id:
		var b: Dictionary = _by_id[id]
		var d := def(b["key"])
		var r := footprint(b["key"], b["origin"])
		# Floor row and door support row are adjacent to the footprint.
		if d != null and r.grow(1).intersects(rect) and not _has_support(d, r):
			lost.append(id)
	lost.sort_custom(func(a: String, b: String) -> bool: return _id_num(a) < _id_num(b))
	for id in lost:
		if not _by_id.has(id):
			continue
		var b: Dictionary = _by_id[id]
		var materials: Dictionary = (b["materials"] as Dictionary).duplicate()
		remove(id)
		building_lost.emit(id, b["key"], b["origin"], materials)


static func _id_num(id: String) -> int:
	return int(id.substr(id.rfind(StableIdAllocator.SEPARATOR) + 1))
