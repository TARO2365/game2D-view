class_name StockpileZones
extends RefCounted
## Player-designated storage tiles and their incoming-capacity bookings
## (M2 contract §1, §4). A zone tile is valid when it is in bounds, not solid
## (an NPC can stand there) and the tile directly below is solid (items rest
## on a floor). Tiles that stop being valid after terrain changes are removed
## automatically, together with any booking on them.
##
## Capacity: free = TILE_CAPACITY_KG - ground kg on the tile - booked kg.
## Bookings are keyed by job id; JobManager decides who books what. One job
## holds at most one booking (booking again replaces the old one).
## zones_changed is emitted only when the set of zone tiles changes.

signal zones_changed(rect: Rect2i)

const TILE_CAPACITY_KG := 1000.0  # PLACEHOLDER (spec §17 tuning)
const NO_TILE := Vector2i(-1, -1)

var grid: WorldGrid
var inventory: Inventory

var _zones: Dictionary = {}       # tile index -> true
var _bookings: Dictionary = {}    # job id -> {"tile": Vector2i, "kg": float}
var _booked: Dictionary = {}      # tile index -> float total booked kg


func _init(world_grid: WorldGrid, inv: Inventory) -> void:
	grid = world_grid
	inventory = inv
	grid.tiles_changed.connect(_on_tiles_changed)


# --- Queries ------------------------------------------------------------

func is_valid_tile(tile: Vector2i) -> bool:
	if not grid.in_bounds(tile):
		return false
	if grid.registry.is_solid(grid.get_tile(tile)):
		return false
	var below := tile + Vector2i.DOWN
	# Out of bounds below counts as solid (same rule as WorldGrid.is_solid_at, §2).
	return not grid.in_bounds(below) or grid.registry.is_solid(grid.get_tile(below))


func is_stockpile(tile: Vector2i) -> bool:
	return grid.in_bounds(tile) and _zones.has(_index(tile))


## Zone tiles in row-major order (deterministic).
func tiles() -> Array[Vector2i]:
	var keys := _zones.keys()
	keys.sort()
	var out: Array[Vector2i] = []
	for k: int in keys:
		out.append(_tile_of(k))
	return out


func count() -> int:
	return _zones.size()


func booked_kg(tile: Vector2i) -> float:
	if not grid.in_bounds(tile):
		return 0.0
	return float(_booked.get(_index(tile), 0.0))


## Tile booked by job_id, or NO_TILE (e.g. after the zone was removed).
func booked_tile(job_id: String) -> Vector2i:
	var b: Variant = _bookings.get(job_id)
	return b["tile"] if b != null else NO_TILE


## 0 for tiles that are not stockpile tiles; never negative.
func free_capacity(tile: Vector2i) -> float:
	if not is_stockpile(tile):
		return 0.0
	return maxf(0.0, TILE_CAPACITY_KG - inventory.ground_kg_at(tile) - booked_kg(tile))


## Nearest zone tile (Manhattan) with free_capacity >= kg; ties: smaller y,
## then smaller x. Vector2i(-1, -1) if none.
func find_drop_tile(kg: float, near: Vector2i) -> Vector2i:
	var best := NO_TILE
	var best_d := 0
	for t in tiles():  # row-major, so the first of equal distance wins the tie
		if free_capacity(t) + Inventory.KG_EPSILON < kg:
			continue
		var d := absi(t.x - near.x) + absi(t.y - near.y)
		if best == NO_TILE or d < best_d:
			best = t
			best_d = d
	return best


func is_stored(item: ItemStack) -> bool:
	return item != null and item.holder == Inventory.Holder.GROUND and is_stockpile(item.tile)


# --- Commands -----------------------------------------------------------

func designate(rect: Rect2i) -> CommandResult:
	var r := rect.intersection(grid.bounds())
	if not r.has_area():
		return CommandResult.failure(&"out_of_bounds", "Selection is outside the world")
	var added := 0
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var p := Vector2i(x, y)
			var idx := _index(p)
			if _zones.has(idx) or not is_valid_tile(p):
				continue
			_zones[idx] = true
			added += 1
	if added == 0:
		return CommandResult.failure(&"nothing_to_designate",
				"No tile in the selection can hold a stockpile")
	zones_changed.emit(r)
	return CommandResult.success({"added": added, "skipped": r.get_area() - added})


func remove(rect: Rect2i) -> CommandResult:
	var r := rect.intersection(grid.bounds())
	var removed := _remove_in(r, false)
	if removed == 0:
		return CommandResult.failure(&"nothing_to_remove", "No stockpile in the selection")
	zones_changed.emit(r)
	return CommandResult.success({"removed": removed})


## Reserves kg of incoming capacity on tile for job_id (replaces the job's
## previous booking; on failure the previous booking is kept).
func book(tile: Vector2i, kg: float, job_id: String) -> CommandResult:
	if job_id.is_empty():
		return CommandResult.failure(&"invalid_job", "No job given")
	if not is_finite(kg) or kg <= 0.0:
		return CommandResult.failure(&"invalid_kg", "Booking needs kg > 0")
	if not is_stockpile(tile):
		return CommandResult.failure(&"not_stockpile", "Tile %s is not a stockpile" % tile)
	var free := free_capacity(tile)
	var old: Variant = _bookings.get(job_id)
	if old != null and old["tile"] == tile:
		free += float(old["kg"])
	if free + Inventory.KG_EPSILON < kg:
		return CommandResult.failure(&"no_capacity", "Not enough free space on %s" % tile,
				{"free": free})
	release(job_id)
	_bookings[job_id] = {"tile": tile, "kg": kg}
	var idx := _index(tile)
	_booked[idx] = float(_booked.get(idx, 0.0)) + kg
	return CommandResult.success({"tile": tile, "kg": kg})


func release(job_id: String) -> void:
	var b: Variant = _bookings.get(job_id)
	if b == null:
		return
	_bookings.erase(job_id)
	var idx := _index(b["tile"])
	var left := float(_booked.get(idx, 0.0)) - float(b["kg"])
	if left <= Inventory.KG_EPSILON:
		_booked.erase(idx)
	else:
		_booked[idx] = left


# --- Persistence --------------------------------------------------------

func to_snapshot() -> Dictionary:
	var keys := _zones.keys()
	keys.sort()
	var jobs := _bookings.keys()
	jobs.sort()
	var bookings: Array = []
	for j: String in jobs:
		bookings.append({"job_id": j, "tile": _bookings[j]["tile"], "kg": _bookings[j]["kg"]})
	return {"indices": PackedInt32Array(keys), "bookings": bookings}


## Restores zones + bookings, dropping invalid tiles and malformed bookings.
## Returns the number of dropped entries.
func load_snapshot(s: Dictionary) -> int:
	_zones.clear()
	_bookings.clear()
	_booked.clear()
	var dropped := 0
	var idx_v: Variant = s.get("indices")
	if typeof(idx_v) == TYPE_PACKED_INT32_ARRAY:
		var total := grid.width * grid.height
		for idx: int in idx_v:
			if idx < 0 or idx >= total or not is_valid_tile(_tile_of(idx)):
				dropped += 1
				continue
			_zones[idx] = true
	var b_v: Variant = s.get("bookings")
	if typeof(b_v) == TYPE_ARRAY:
		for e: Variant in b_v:
			if not _load_booking(e):
				dropped += 1
	zones_changed.emit(grid.bounds())
	return dropped


func _load_booking(e: Variant) -> bool:
	if typeof(e) != TYPE_DICTIONARY:
		return false
	var d: Dictionary = e
	var j: Variant = d.get("job_id")
	var t: Variant = d.get("tile")
	var kg: Variant = d.get("kg")
	if typeof(j) != TYPE_STRING or String(j).is_empty() or _bookings.has(j):
		return false
	if typeof(t) != TYPE_VECTOR2I or not is_stockpile(t):
		return false
	if (typeof(kg) != TYPE_FLOAT and typeof(kg) != TYPE_INT) or not is_finite(float(kg)) \
			or float(kg) <= 0.0:
		return false
	_bookings[j] = {"tile": t, "kg": float(kg)}
	var idx := _index(t)
	_booked[idx] = float(_booked.get(idx, 0.0)) + float(kg)
	return true


# --- Internals ----------------------------------------------------------

func _on_tiles_changed(rect: Rect2i) -> void:
	# A changed tile also affects validity of the tile directly above it.
	var r := Rect2i(rect.position + Vector2i.UP, rect.size + Vector2i(0, 1)).intersection(grid.bounds())
	if _remove_in(r, true) > 0:
		zones_changed.emit(r)


func _remove_in(r: Rect2i, only_invalid: bool) -> int:
	if not r.has_area() or _zones.is_empty():
		return 0
	var removed := 0
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var p := Vector2i(x, y)
			var idx := _index(p)
			if not _zones.has(idx):
				continue
			if only_invalid and is_valid_tile(p):
				continue
			_zones.erase(idx)
			_drop_bookings_on(p)
			removed += 1
	return removed


func _drop_bookings_on(tile: Vector2i) -> void:
	var jobs: Array = []
	for j: String in _bookings:
		if _bookings[j]["tile"] == tile:
			jobs.append(j)
	for j: String in jobs:
		release(j)


func _index(p: Vector2i) -> int:
	return p.y * grid.width + p.x


func _tile_of(idx: int) -> Vector2i:
	return Vector2i(idx % grid.width, idx / grid.width)
