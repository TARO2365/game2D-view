class_name DesignationMap
extends RefCounted
## Player orders per tile ("dig here", "build wall here") — D-015.
## The player never edits terrain; designations persist with the world and,
## from M2, JobManager turns them into NPC jobs. This map owns designations
## only and never modifies terrain. Designations made invalid by terrain
## changes are removed automatically.

signal designations_changed(rect: Rect2i)

enum Kind { NONE = 0, DIG = 1, BUILD_WALL = 2 }

var grid: WorldGrid
var _by_index: Dictionary = {}  # tile index -> Kind


func _init(world_grid: WorldGrid) -> void:
	grid = world_grid
	grid.tiles_changed.connect(_on_tiles_changed)


func count() -> int:
	return _by_index.size()


func get_kind(p: Vector2i) -> int:
	return _by_index.get(p.y * grid.width + p.x, Kind.NONE)


## Read-only view for rendering: tile index -> Kind.
func entries() -> Dictionary:
	return _by_index


func is_valid_for(kind: int, tile_id: int) -> bool:
	match kind:
		Kind.DIG:
			return grid.can_dig(tile_id)
		Kind.BUILD_WALL:
			return grid.can_build(tile_id)
	return false


func designate(rect: Rect2i, kind: Kind) -> CommandResult:
	if kind == Kind.NONE:
		return CommandResult.failure(&"invalid_kind", "Unknown order type")
	var r := rect.intersection(grid.bounds())
	if not r.has_area():
		return CommandResult.failure(&"out_of_bounds", "Selection is outside the world")
	var t := grid.tiles
	var added := 0
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var idx := y * grid.width + x
			if _by_index.get(idx, Kind.NONE) == kind or not is_valid_for(kind, t[idx]):
				continue
			_by_index[idx] = kind
			added += 1
	if added == 0:
		return CommandResult.failure(&"nothing_to_designate",
				"Nothing in the selection can be %s" % ("dug" if kind == Kind.DIG else "built on"))
	designations_changed.emit(r)
	return CommandResult.success({"added": added, "skipped": r.get_area() - added})


func cancel(rect: Rect2i) -> CommandResult:
	var r := rect.intersection(grid.bounds())
	var removed := _remove_in(r, false)
	if removed == 0:
		return CommandResult.failure(&"nothing_to_cancel", "No orders in the selection")
	designations_changed.emit(r)
	return CommandResult.success({"removed": removed})


func to_snapshot() -> Dictionary:
	var keys := _by_index.keys()
	keys.sort()
	var kinds := PackedByteArray()
	for k in keys:
		kinds.append(_by_index[k])
	return {"indices": PackedInt32Array(keys), "kinds": kinds}


## Returns number of entries dropped as invalid.
func load_snapshot(snapshot: Dictionary) -> int:
	_by_index.clear()
	var idx_v: Variant = snapshot.get("indices")
	var kind_v: Variant = snapshot.get("kinds")
	if typeof(idx_v) != TYPE_PACKED_INT32_ARRAY or typeof(kind_v) != TYPE_PACKED_BYTE_ARRAY:
		return 0
	var indices: PackedInt32Array = idx_v
	var kinds: PackedByteArray = kind_v
	if indices.size() != kinds.size():
		return indices.size()
	var dropped := 0
	var t := grid.tiles
	for i in indices.size():
		var idx := indices[i]
		var kind := kinds[i]
		if idx < 0 or idx >= t.size() or not is_valid_for(kind, t[idx]):
			dropped += 1
			continue
		_by_index[idx] = kind
	return dropped


func _on_tiles_changed(rect: Rect2i) -> void:
	if _remove_in(rect, true) > 0:
		designations_changed.emit(rect)


func _remove_in(r: Rect2i, only_invalid: bool) -> int:
	if not r.has_area() or _by_index.is_empty():
		return 0
	var t := grid.tiles
	var removed := 0
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var idx := y * grid.width + x
			if not _by_index.has(idx):
				continue
			if only_invalid and is_valid_for(_by_index[idx], t[idx]):
				continue
			_by_index.erase(idx)
			removed += 1
	return removed
