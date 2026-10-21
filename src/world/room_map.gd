class_name RoomMap
extends RefCounted
## Rooms: derived state, recomputed incrementally, never saved (M3 contract §3).
## A room is a 4-connected set of non-solid, non-door tiles bounded by solid
## tiles / door tiles, with at most MAX_ROOM_TILES tiles, not touching the
## world border or any tile above the surface line (open sky).
## Type (M4a order, D-028): bedroom (bed) > kitchen > dining (table) >
## storage (crate) > farm (farm plot) > &"room".
##
## Only the area around a `tiles_changed` / `buildings_changed` rect is
## recomputed: rooms overlapping the rect grown by one tile are dissolved and
## their tiles plus the open tiles of the grown rect are re-flooded. Every
## flood fill stops after MAX_ROOM_TILES + 1 tiles, so the work per change is
## bounded. Call rebuild_all() after loading.

signal rooms_changed(rect: Rect2i)

const MAX_ROOM_TILES := 128  # PLACEHOLDER (D-021)
## First match wins.
const TYPE_ORDER: Array[StringName] = [&"bedroom", &"kitchen", &"dining", &"storage", &"farm"]
const TYPE_ROOM := &"room"

var grid: WorldGrid
var buildings: Buildings
## Room id per tile (0 = no room). Row-major like grid.tiles.
var _room_of := PackedInt32Array()
## id -> {"tiles": PackedInt32Array (sorted), "type": StringName, "bounds": Rect2i,
##        "building_ids": Array[String]}
var _rooms: Dictionary = {}
var _next_id := 1
var _solid_by_id := PackedByteArray()  # tile id -> 1 if solid


func _init(world_grid: WorldGrid, world_buildings: Buildings) -> void:
	grid = world_grid
	buildings = world_buildings
	_room_of.resize(grid.width * grid.height)
	for id in grid.registry.max_id() + 1:
		_solid_by_id.append(1 if grid.registry.is_solid(id) else 0)
	# Buildings forwards every place/remove/loss to grid.tiles_changed (same
	# footprint) before buildings_changed, so listening to the grid covers both
	# without recomputing twice.
	grid.tiles_changed.connect(_on_changed)
	rebuild_all()


## {} if no room; else {id (runtime only), type, size, bounds, building_ids}.
func room_at(tile: Vector2i) -> Dictionary:
	if not grid.in_bounds(tile):
		return {}
	var id := _room_of[tile.y * grid.width + tile.x]
	return _public(id) if id != 0 else {}


## Sorted by id.
func all_rooms() -> Array[Dictionary]:
	var ids := _rooms.keys()
	ids.sort()
	var out: Array[Dictionary] = []
	for id: int in ids:
		out.append(_public(id))
	return out


func room_count() -> int:
	return _rooms.size()


## Sorted tile indices (y * width + x) of a room; empty if unknown.
func room_tiles(id: int) -> PackedInt32Array:
	if not _rooms.has(id):
		return PackedInt32Array()
	return (_rooms[id]["tiles"] as PackedInt32Array).duplicate()


## Recomputes every room (use after loading a world).
func rebuild_all() -> void:
	_room_of.fill(0)
	var had := not _rooms.is_empty()
	_rooms.clear()
	var visited := {}
	var created := 0
	for y in grid.height:
		for x in grid.width:
			if y < grid.surface_y[x]:
				continue  # open sky: can never be part of a room
			var idx := y * grid.width + x
			if visited.has(idx) or _is_wall(idx):
				continue
			if _flood(idx, visited) != 0:
				created += 1
	if had or created > 0:
		rooms_changed.emit(grid.bounds())


# --- Incremental update -------------------------------------------------

func _on_changed(rect: Rect2i) -> void:
	var area := rect.grow(1).intersection(grid.bounds())
	if not area.has_area():
		return
	var w := grid.width
	var dirty := area
	var seeds := PackedInt32Array()
	# Dissolve rooms touching the area; their tiles become seeds.
	var dissolved := {}
	for y in range(area.position.y, area.end.y):
		for x in range(area.position.x, area.end.x):
			var rid := _room_of[y * w + x]
			if rid != 0 and not dissolved.has(rid):
				dissolved[rid] = true
	for rid: int in dissolved:
		var room: Dictionary = _rooms[rid]
		var tiles: PackedInt32Array = room["tiles"]
		for i in tiles:
			_room_of[i] = 0
		seeds.append_array(tiles)
		dirty = dirty.merge(room["bounds"])
		_rooms.erase(rid)
	for y in range(area.position.y, area.end.y):
		for x in range(area.position.x, area.end.x):
			seeds.append(y * w + x)
	var visited := {}
	var created := 0
	for idx in seeds:
		if visited.has(idx) or _is_wall(idx):
			continue
		var rid := _flood(idx, visited)
		if rid != 0:
			created += 1
			dirty = dirty.merge(_rooms[rid]["bounds"])
	if created > 0 or not dissolved.is_empty():
		rooms_changed.emit(dirty)


## Bounded flood fill from `start`. Creates a room when the region is closed
## and small enough; returns its id, else 0. Tiles reached are added to
## `visited`. Reaching a tile visited by an earlier flood of the same pass
## means that region was already found open.
func _flood(start: int, visited: Dictionary) -> int:
	var w := grid.width
	var h := grid.height
	var region := PackedInt32Array([start])
	visited[start] = true
	var open := false
	var head := 0
	while head < region.size():
		var idx := region[head]
		head += 1
		var x := idx % w
		var y := idx / w
		if x == 0 or y == 0 or x == w - 1 or y == h - 1 or y < grid.surface_y[x]:
			open = true
			break
		for n: int in [idx - 1, idx + 1, idx - w, idx + w]:
			if _is_wall(n):
				continue
			if visited.has(n):
				if region.find(n) == -1:
					open = true  # joins a region already found open in this pass
					break
				continue
			visited[n] = true
			region.append(n)
			if region.size() > MAX_ROOM_TILES:
				open = true
				break
		if open:
			break
	if open:
		return 0
	return _create_room(region)


func _create_room(region: PackedInt32Array) -> int:
	var w := grid.width
	region.sort()
	var rid := _next_id
	_next_id += 1
	var min_p := Vector2i(grid.width, grid.height)
	var max_p := Vector2i(-1, -1)
	var ids: Array[String] = []
	var tags := {}
	for idx in region:
		_room_of[idx] = rid
		var p := Vector2i(idx % w, idx / w)
		min_p = Vector2i(mini(min_p.x, p.x), mini(min_p.y, p.y))
		max_p = Vector2i(maxi(max_p.x, p.x), maxi(max_p.y, p.y))
		var bid := buildings.building_at(p)
		if not bid.is_empty() and not ids.has(bid):
			ids.append(bid)
			tags[buildings.room_tag_at(p)] = true
	ids.sort_custom(func(a: String, b: String) -> bool: return Buildings._id_num(a) < Buildings._id_num(b))
	var room_type := TYPE_ROOM
	for t in TYPE_ORDER:
		if tags.has(t):
			room_type = t
			break
	_rooms[rid] = {"tiles": region, "type": room_type, "bounds": Rect2i(min_p, max_p - min_p + Vector2i.ONE),
			"building_ids": ids}
	return rid


func _is_wall(idx: int) -> bool:
	var t := grid.tiles[idx]
	if t < _solid_by_id.size() and _solid_by_id[t] == 1:
		return true
	if t >= _solid_by_id.size() and grid.registry.is_solid(t):
		return true
	var w := grid.width
	return buildings.is_door(Vector2i(idx % w, idx / w))


func _public(id: int) -> Dictionary:
	var r: Dictionary = _rooms[id]
	return {"id": id, "type": r["type"], "size": (r["tiles"] as PackedInt32Array).size(),
			"bounds": r["bounds"], "building_ids": (r["building_ids"] as Array[String]).duplicate()}
