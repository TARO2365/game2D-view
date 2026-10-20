class_name DesignationMap
extends RefCounted
## Player orders per tile ("dig here", "build wall/ladder here") — D-015.
## The player never edits terrain; designations persist with the world and
## JobManager turns them into NPC jobs. This map owns designations and their
## priorities only and never modifies terrain. Designations made invalid by
## terrain/structure changes are removed automatically.

signal designations_changed(rect: Rect2i)

## Stored in save files: NEVER renumber or reuse a value.
enum Kind { NONE = 0, DIG = 1, BUILD_WALL = 2, BUILD_LADDER = 3, DECONSTRUCT = 4 }

const DEFAULT_PRIORITY := 5
const MIN_PRIORITY := 1
const MAX_PRIORITY := 9

var grid: WorldGrid
var _by_index: Dictionary = {}  # tile index -> Kind
var _priority: Dictionary = {}  # tile index -> 1..9


func _init(world_grid: WorldGrid) -> void:
	grid = world_grid
	grid.tiles_changed.connect(_on_tiles_changed)


func count() -> int:
	return _by_index.size()


func get_kind(p: Vector2i) -> int:
	return _by_index.get(p.y * grid.width + p.x, Kind.NONE)


func get_priority(p: Vector2i) -> int:
	return _priority.get(p.y * grid.width + p.x, DEFAULT_PRIORITY)


## Read-only view for rendering/jobs: tile index -> Kind.
func entries() -> Dictionary:
	return _by_index


func is_valid_for(kind: int, tile_id: int, structure: int = WorldGrid.Structure.NONE,
		has_building: bool = false) -> bool:
	match kind:
		Kind.DIG:
			return grid.can_dig(tile_id)
		Kind.BUILD_WALL, Kind.BUILD_LADDER:
			return grid.can_build(tile_id) and structure == WorldGrid.Structure.NONE and not has_building
		Kind.DECONSTRUCT:
			# Player-built things only: concrete walls, ladders, buildings (M3 contract §5).
			return grid.can_deconstruct(tile_id) or structure != WorldGrid.Structure.NONE or has_building
	return false


func designate(rect: Rect2i, kind: Kind, priority: int = DEFAULT_PRIORITY) -> CommandResult:
	if kind == Kind.NONE or kind not in Kind.values():
		return CommandResult.failure(&"invalid_kind", "Unknown order type")
	if priority < MIN_PRIORITY or priority > MAX_PRIORITY:
		return CommandResult.failure(&"invalid_priority", "Priority must be %d-%d" % [MIN_PRIORITY, MAX_PRIORITY])
	var r := rect.intersection(grid.bounds())
	if not r.has_area():
		return CommandResult.failure(&"out_of_bounds", "Selection is outside the world")
	var added := 0
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var idx := y * grid.width + x
			if _by_index.get(idx, Kind.NONE) == kind or not _valid_at(kind, idx):
				continue
			_by_index[idx] = kind  # a different build order on the same tile is replaced
			_priority[idx] = priority
			added += 1
	if added == 0:
		var verb := "dug" if kind == Kind.DIG else ("deconstructed" if kind == Kind.DECONSTRUCT else "built on")
		return CommandResult.failure(&"nothing_to_designate", "Nothing in the selection can be %s" % verb)
	designations_changed.emit(r)
	return CommandResult.success({"added": added, "skipped": r.get_area() - added})


func set_priority(rect: Rect2i, priority: int) -> CommandResult:
	if priority < MIN_PRIORITY or priority > MAX_PRIORITY:
		return CommandResult.failure(&"invalid_priority", "Priority must be %d-%d" % [MIN_PRIORITY, MAX_PRIORITY])
	var r := rect.intersection(grid.bounds())
	var changed := 0
	if r.has_area():
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				var idx := y * grid.width + x
				if _by_index.has(idx) and _priority.get(idx, DEFAULT_PRIORITY) != priority:
					_priority[idx] = priority
					changed += 1
	if changed == 0:
		return CommandResult.failure(&"nothing_to_change", "No orders to re-prioritise in the selection")
	designations_changed.emit(r)
	return CommandResult.success({"changed": changed})


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
	var prios := PackedByteArray()
	for k in keys:
		kinds.append(_by_index[k])
		prios.append(_priority.get(k, DEFAULT_PRIORITY))
	return {"indices": PackedInt32Array(keys), "kinds": kinds, "priorities": prios}


## Returns number of entries dropped as invalid. Snapshots without
## "priorities" (save v1) get DEFAULT_PRIORITY.
func load_snapshot(snapshot: Dictionary) -> int:
	_by_index.clear()
	_priority.clear()
	var idx_v: Variant = snapshot.get("indices")
	var kind_v: Variant = snapshot.get("kinds")
	if typeof(idx_v) != TYPE_PACKED_INT32_ARRAY or typeof(kind_v) != TYPE_PACKED_BYTE_ARRAY:
		return 0
	var indices: PackedInt32Array = idx_v
	var kinds: PackedByteArray = kind_v
	if indices.size() != kinds.size():
		return indices.size()
	var prio_v: Variant = snapshot.get("priorities")
	var prios := PackedByteArray()
	if typeof(prio_v) == TYPE_PACKED_BYTE_ARRAY and (prio_v as PackedByteArray).size() == indices.size():
		prios = prio_v
	var dropped := 0
	for i in indices.size():
		var idx := indices[i]
		var kind := kinds[i]
		if idx < 0 or idx >= grid.tiles.size() or not _valid_at(kind, idx):
			dropped += 1
			continue
		_by_index[idx] = kind
		var p := prios[i] if not prios.is_empty() else DEFAULT_PRIORITY
		_priority[idx] = clampi(p, MIN_PRIORITY, MAX_PRIORITY)
	return dropped


func _valid_at(kind: int, idx: int) -> bool:
	var p := Vector2i(idx % grid.width, idx / grid.width)
	return is_valid_for(kind, grid.tiles[idx], grid.structures[idx], grid.has_building(p))


func _on_tiles_changed(rect: Rect2i) -> void:
	if _remove_in(rect, true) > 0:
		designations_changed.emit(rect)


func _remove_in(r: Rect2i, only_invalid: bool) -> int:
	if not r.has_area() or _by_index.is_empty():
		return 0
	var removed := 0
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var idx := y * grid.width + x
			if not _by_index.has(idx):
				continue
			if only_invalid and _valid_at(_by_index[idx], idx):
				continue
			_by_index.erase(idx)
			_priority.erase(idx)
			removed += 1
	return removed
