class_name BuildOrders
extends RefCounted
## Player orders to place multi-tile buildings (door, crate, bed, table) —
## M3 contract §5. Owns the orders and their priorities only; JobManager turns
## each order into one build job (haul material -> work -> Buildings.place).
##
## An order is valid while Buildings.can_place(key, origin) holds and its
## footprint overlaps no other building order and no tile designation (dig /
## wall / ladder / deconstruct). Orders made invalid by terrain or building
## changes are removed automatically (orders_changed is emitted). A new tile
## designation on an order's footprint replaces the order (newest wins).

signal orders_changed(rect: Rect2i)

const ID_CATEGORY := &"bord"

var grid: WorldGrid
var buildings: Buildings
var designations: DesignationMap

var _ids: StableIdAllocator
var _orders: Dictionary = {}  # order id -> {"key": StringName, "origin": Vector2i, "priority": int}
var _occ: Dictionary = {}     # tile index -> order id


func _init(world_grid: WorldGrid, world_buildings: Buildings, designation_map: DesignationMap,
		ids: StableIdAllocator) -> void:
	grid = world_grid
	buildings = world_buildings
	designations = designation_map
	_ids = ids
	grid.tiles_changed.connect(_on_tiles_changed)
	designations.designations_changed.connect(_on_designations_changed)


# --- Commands -----------------------------------------------------------

## data["id"] = new order id. Failure codes: invalid_priority, unknown_key,
## out_of_bounds, blocked, no_floor, no_support (from Buildings.can_place),
## overlaps_order, overlaps_designation.
func order_building(key: StringName, origin: Vector2i,
		priority: int = DesignationMap.DEFAULT_PRIORITY) -> CommandResult:
	if priority < DesignationMap.MIN_PRIORITY or priority > DesignationMap.MAX_PRIORITY:
		return CommandResult.failure(&"invalid_priority", "Priority must be %d-%d" % [
				DesignationMap.MIN_PRIORITY, DesignationMap.MAX_PRIORITY])
	var check := buildings.can_place(key, origin)
	if not check.ok:
		return check
	var r := buildings.footprint(key, origin)
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var p := Vector2i(x, y)
			if _occ.has(_idx(p)):
				return CommandResult.failure(&"overlaps_order", "Another building is ordered there",
						{"tile": p})
			if designations.get_kind(p) != DesignationMap.Kind.NONE:
				return CommandResult.failure(&"overlaps_designation", "Another order is on that tile",
						{"tile": p})
	var id := _ids.allocate(ID_CATEGORY)
	_add(id, key, origin, priority)
	orders_changed.emit(r)
	return CommandResult.success({"id": id, "rect": r})


## Removes every order whose footprint intersects rect. data["removed"].
func cancel_at(rect: Rect2i) -> CommandResult:
	var gone: Array[String] = []
	for id: String in _orders:
		if _footprint(id).intersects(rect):
			gone.append(id)
	if gone.is_empty():
		return CommandResult.failure(&"nothing_to_cancel", "No building orders in the selection")
	var changed := _remove_all(gone)
	orders_changed.emit(changed)
	return CommandResult.success({"removed": gone.size()})


## Changes the priority of every order intersecting rect. data["changed"].
func set_priority(rect: Rect2i, priority: int) -> CommandResult:
	if priority < DesignationMap.MIN_PRIORITY or priority > DesignationMap.MAX_PRIORITY:
		return CommandResult.failure(&"invalid_priority", "Priority must be %d-%d" % [
				DesignationMap.MIN_PRIORITY, DesignationMap.MAX_PRIORITY])
	var changed := 0
	var area := Rect2i()
	for id: String in _orders:
		var fp := _footprint(id)
		if fp.intersects(rect) and int(_orders[id]["priority"]) != priority:
			_orders[id]["priority"] = priority
			changed += 1
			area = fp if not area.has_area() else area.merge(fp)
	if changed == 0:
		return CommandResult.failure(&"nothing_to_change", "No building orders to re-prioritise")
	orders_changed.emit(area)
	return CommandResult.success({"changed": changed})


## Used by JobManager when the building has been placed (or the job is gone
## for good). Emits orders_changed.
func remove(id: String) -> CommandResult:
	if not _orders.has(id):
		return CommandResult.failure(&"unknown_order", "No building order %s" % id)
	var r := _remove_all([id] as Array[String])
	orders_changed.emit(r)
	return CommandResult.success({"rect": r})


# --- Queries ------------------------------------------------------------

## [{id, key, origin, priority}] in creation order.
func orders() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id in _sorted_ids():
		out.append(get_order(id))
	return out


func get_order(id: String) -> Dictionary:
	if not _orders.has(id):
		return {}
	var o: Dictionary = _orders[id]
	return {"id": id, "key": o["key"], "origin": o["origin"], "priority": o["priority"]}


## The order covering tile, or {}.
func order_at(tile: Vector2i) -> Dictionary:
	if not grid.in_bounds(tile):
		return {}
	return get_order(_occ.get(_idx(tile), ""))


func footprint_of(id: String) -> Rect2i:
	return _footprint(id) if _orders.has(id) else Rect2i()


func count() -> int:
	return _orders.size()


# --- Persistence --------------------------------------------------------

## Plain types only: {"orders": [{id, key, x, y, priority}]}.
func to_snapshot() -> Dictionary:
	var list: Array = []
	for id in _sorted_ids():
		var o: Dictionary = _orders[id]
		var p: Vector2i = o["origin"]
		list.append({"id": id, "key": String(o["key"]), "x": p.x, "y": p.y, "priority": o["priority"]})
	return {"orders": list}


## Load after Buildings and DesignationMap. Drops malformed / duplicate /
## no-longer-placeable / overlapping entries; returns the number dropped.
## Emits no signal (JobManager.load_snapshot syncs jobs with the orders).
func load_snapshot(s: Dictionary) -> int:
	_orders.clear()
	_occ.clear()
	var dropped := 0
	var list_v: Variant = s.get("orders")
	if typeof(list_v) != TYPE_ARRAY:
		return 0
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
	var p_v: Variant = d.get("priority", DesignationMap.DEFAULT_PRIORITY)
	if typeof(id_v) != TYPE_STRING or not (typeof(key_v) in [TYPE_STRING, TYPE_STRING_NAME]) \
			or typeof(x_v) != TYPE_INT or typeof(y_v) != TYPE_INT or typeof(p_v) != TYPE_INT:
		return false
	var id: String = id_v
	if not StableIdAllocator.is_valid(id) or StableIdAllocator.category_of(id) != ID_CATEGORY \
			or _orders.has(id):
		return false
	var key := StringName(key_v)
	var origin := Vector2i(x_v, y_v)
	if not buildings.can_place(key, origin).ok:
		return false
	var r := buildings.footprint(key, origin)
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var p := Vector2i(x, y)
			if _occ.has(_idx(p)) or designations.get_kind(p) != DesignationMap.Kind.NONE:
				return false
	_add(id, key, origin, clampi(p_v, DesignationMap.MIN_PRIORITY, DesignationMap.MAX_PRIORITY))
	return true


# --- Internals ----------------------------------------------------------

func _add(id: String, key: StringName, origin: Vector2i, priority: int) -> void:
	_orders[id] = {"key": key, "origin": origin, "priority": priority}
	var r := buildings.footprint(key, origin)
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			_occ[y * grid.width + x] = id


## Removes orders; returns the merged footprint rect.
func _remove_all(ids: Array[String]) -> Rect2i:
	var area := Rect2i()
	for id in ids:
		if not _orders.has(id):
			continue
		var r := _footprint(id)
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				_occ.erase(y * grid.width + x)
		_orders.erase(id)
		area = r if not area.has_area() else area.merge(r)
	return area


func _footprint(id: String) -> Rect2i:
	var o: Dictionary = _orders[id]
	return buildings.footprint(o["key"], o["origin"])


## Terrain / structure / building change: orders whose footprint (or the
## floor / door support next to it) was touched are re-validated.
func _on_tiles_changed(rect: Rect2i) -> void:
	if _orders.is_empty():
		return
	var gone: Array[String] = []
	for id: String in _orders:
		var fp := _footprint(id)
		if fp.grow(1).intersects(rect):
			var o: Dictionary = _orders[id]
			if not buildings.can_place(o["key"], o["origin"]).ok:
				gone.append(id)
	if not gone.is_empty():
		orders_changed.emit(_remove_all(gone))


## A tile designation placed on an order's footprint replaces the order.
func _on_designations_changed(rect: Rect2i) -> void:
	if _orders.is_empty():
		return
	var gone: Array[String] = []
	for id: String in _orders:
		var fp := _footprint(id).intersection(rect)
		if not fp.has_area():
			continue
		var hit := false
		for y in range(fp.position.y, fp.end.y):
			for x in range(fp.position.x, fp.end.x):
				if designations.get_kind(Vector2i(x, y)) != DesignationMap.Kind.NONE:
					hit = true
		if hit:
			gone.append(id)
	if not gone.is_empty():
		orders_changed.emit(_remove_all(gone))


func _sorted_ids() -> Array[String]:
	var out: Array[String] = []
	for id: String in _orders:
		out.append(id)
	out.sort_custom(func(a: String, b: String) -> bool: return _id_num(a) < _id_num(b))
	return out


func _idx(p: Vector2i) -> int:
	return p.y * grid.width + p.x


static func _id_num(id: String) -> int:
	return int(id.substr(id.rfind(StableIdAllocator.SEPARATOR) + 1))
