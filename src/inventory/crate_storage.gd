class_name CrateStorage
extends RefCounted
## Storage crates (M3 contract §4): material filters and incoming-capacity
## bookings for every building whose definition has storage_kg > 0. The
## items themselves live in Inventory (holder CRATE, holder_id = building id).
##
## Capacity: free = storage_kg - Inventory.crate_kg - booked kg.
## Bookings are keyed by job id; JobManager decides who books what. One job
## holds at most one booking (booking again replaces the old one).
## When a crate building is removed or lost its filter and bookings are
## dropped here; JobManager moves its items out via
## Inventory.empty_crate_to_ground (this class never mutates Inventory).
##
## crates_changed(building_id) is emitted when a crate appears or disappears
## and when its filter changes; an empty id means "everything changed" (load).
## Booking changes do not emit (same as StockpileZones).
##
## NOTE (Systems Agent, M3): the contract types the provider as `Buildings`
## (src/world/buildings.gd, World Agent), which did not exist while this was
## written. It is held as a duck-typed RefCounted and only contract members
## are used: all_ids(), get_building(id), def(key).storage_kg and the signals
## buildings_changed / building_lost. Lead: switch the type to `Buildings`
## when merging (and replace the call()/connect() by direct calls if wanted).

signal crates_changed(building_id: String)

var inventory: Inventory

var _buildings: RefCounted        # Buildings provider (see NOTE above)
var _known: Dictionary = {}       # crate building id -> true (last seen set)
var _filters: Dictionary = {}     # building id -> Array[StringName] (sorted, unique, non-empty)
var _bookings: Dictionary = {}    # job id -> {"building_id": String, "kg": float}
var _booked: Dictionary = {}      # building id -> float total booked kg


func _init(buildings: RefCounted, inv: Inventory) -> void:
	_buildings = buildings
	inventory = inv
	_buildings.connect(&"buildings_changed", _on_buildings_changed)
	_buildings.connect(&"building_lost", _on_building_lost)
	for id in crate_ids():
		_known[id] = true


# --- Queries ------------------------------------------------------------

## Ids of all crate buildings, ordered by id number (deterministic).
func crate_ids() -> Array[String]:
	var out: Array[String] = []
	var all: Array = _buildings.call(&"all_ids")
	for v: Variant in all:
		var id := String(v)
		if _storage_kg(id) > 0.0:
			out.append(id)
	out.sort_custom(_less_id)
	return out


func is_crate(building_id: String) -> bool:
	return _storage_kg(building_id) > 0.0


## Empty array = accepts every material.
func get_filter(building_id: String) -> Array[StringName]:
	var out: Array[StringName] = []
	var f: Variant = _filters.get(building_id)
	if f != null:
		out.assign(f)
	return out


func accepts(building_id: String, material: StringName) -> bool:
	if not is_crate(building_id) or String(material).is_empty():
		return false
	var f: Variant = _filters.get(building_id)
	return f == null or (f as Array).has(material)


func booked_kg(building_id: String) -> float:
	return float(_booked.get(building_id, 0.0))


## 0 for ids that are not crates; never negative.
func free_capacity(building_id: String) -> float:
	var cap := _storage_kg(building_id)
	if cap <= 0.0:
		return 0.0
	return maxf(0.0, cap - inventory.crate_kg(building_id) - booked_kg(building_id))


## Crate booked by job_id, or "" (e.g. after the crate was removed).
func booked_crate(job_id: String) -> String:
	var b: Variant = _bookings.get(job_id)
	return b["building_id"] if b != null else ""


## Nearest crate (Manhattan distance from near to the crate origin) that
## accepts material and has free_capacity >= kg; ties: smaller origin y, then
## smaller x, then smaller id number. "" if none.
func find_crate(material: StringName, kg: float, near: Vector2i) -> String:
	if not is_finite(kg) or kg <= 0.0:
		return ""
	var best := ""
	var best_d := 0
	var best_o := Vector2i.ZERO
	for id in crate_ids():  # id order, so equal distance + origin keeps the lower id
		if not accepts(id, material) or free_capacity(id) + Inventory.KG_EPSILON < kg:
			continue
		var o := _origin(id)
		var d := absi(o.x - near.x) + absi(o.y - near.y)
		if best.is_empty() or d < best_d or (d == best_d and (o.y < best_o.y
				or (o.y == best_o.y and o.x < best_o.x))):
			best = id
			best_d = d
			best_o = o
	return best


func is_stored(item: ItemStack) -> bool:
	return item != null and item.holder == Inventory.Holder.CRATE


# --- Commands -----------------------------------------------------------

## Sets the accepted materials of a crate ([] = accept all). Duplicates are
## merged; the stored filter is sorted (deterministic snapshots).
func set_filter(building_id: String, materials: Array[StringName]) -> CommandResult:
	if not is_crate(building_id):
		return CommandResult.failure(&"not_crate", "%s is not a storage crate" % building_id)
	var clean: Array[StringName] = []
	for m in materials:
		if String(m).is_empty():
			return CommandResult.failure(&"invalid_material", "Filter contains an empty material")
		if not clean.has(m):
			clean.append(m)
	clean.sort_custom(_less_name)
	if clean.is_empty():
		_filters.erase(building_id)
	else:
		_filters[building_id] = clean
	crates_changed.emit(building_id)
	return CommandResult.success({"building_id": building_id, "materials": clean.duplicate()})


## Reserves kg of incoming capacity in a crate for job_id (replaces the job's
## previous booking; on failure the previous booking is kept). Filters are
## not checked here: callers use find_crate / accepts first.
func book(building_id: String, kg: float, job_id: String) -> CommandResult:
	if job_id.is_empty():
		return CommandResult.failure(&"invalid_job", "No job given")
	if not is_finite(kg) or kg <= 0.0:
		return CommandResult.failure(&"invalid_kg", "Booking needs kg > 0")
	if not is_crate(building_id):
		return CommandResult.failure(&"not_crate", "%s is not a storage crate" % building_id)
	var free := free_capacity(building_id)
	var old: Variant = _bookings.get(job_id)
	if old != null and old["building_id"] == building_id:
		free += float(old["kg"])
	if free + Inventory.KG_EPSILON < kg:
		return CommandResult.failure(&"no_capacity", "Not enough free space in %s" % building_id,
				{"free": free})
	release(job_id)
	_add_booking(job_id, building_id, kg)
	return CommandResult.success({"building_id": building_id, "kg": kg})


func release(job_id: String) -> void:
	var b: Variant = _bookings.get(job_id)
	if b == null:
		return
	_bookings.erase(job_id)
	var id: String = b["building_id"]
	var left := booked_kg(id) - float(b["kg"])
	if left <= Inventory.KG_EPSILON:
		_booked.erase(id)
	else:
		_booked[id] = left


# --- Persistence --------------------------------------------------------

## Plain-typed snapshot (survives var_to_bytes / bytes_to_var).
func to_snapshot() -> Dictionary:
	var fids := _filters.keys()
	fids.sort_custom(_less_id)
	var filters: Array = []
	for id: String in fids:
		var mats: Array = []
		for m: StringName in _filters[id]:
			mats.append(String(m))
		filters.append({"building_id": id, "materials": mats})
	var jobs := _bookings.keys()
	jobs.sort_custom(_less_id)
	var bookings: Array = []
	for j: String in jobs:
		bookings.append({"job_id": j, "building_id": _bookings[j]["building_id"],
				"kg": _bookings[j]["kg"]})
	return {"filters": filters, "bookings": bookings}


## Restores filters + bookings. Must run after Buildings and Inventory were
## loaded. Drops entries for unknown/non-crate buildings, duplicates and
## malformed values (each junk material inside a filter counts as one).
## Returns the number of dropped entries.
func load_snapshot(s: Dictionary) -> int:
	_filters.clear()
	_bookings.clear()
	_booked.clear()
	_known.clear()
	for id in crate_ids():
		_known[id] = true
	var dropped := 0
	var f_v: Variant = s.get("filters")
	if typeof(f_v) == TYPE_ARRAY:
		for e: Variant in f_v:
			dropped += _load_filter(e)
	var b_v: Variant = s.get("bookings")
	if typeof(b_v) == TYPE_ARRAY:
		for e: Variant in b_v:
			if not _load_booking(e):
				dropped += 1
	crates_changed.emit("")
	return dropped


## Returns the number of dropped parts (1 for a rejected entry, else the
## number of junk materials skipped inside it).
func _load_filter(e: Variant) -> int:
	if typeof(e) != TYPE_DICTIONARY:
		return 1
	var d: Dictionary = e
	var id_v: Variant = d.get("building_id")
	var mats_v: Variant = d.get("materials")
	if typeof(id_v) != TYPE_STRING or not is_crate(id_v) or _filters.has(id_v):
		return 1
	if typeof(mats_v) != TYPE_ARRAY and typeof(mats_v) != TYPE_PACKED_STRING_ARRAY:
		return 1
	var junk := 0
	var clean: Array[StringName] = []
	for m: Variant in mats_v:
		if (typeof(m) != TYPE_STRING and typeof(m) != TYPE_STRING_NAME) or String(m).is_empty():
			junk += 1
			continue
		if not clean.has(StringName(m)):
			clean.append(StringName(m))
	clean.sort_custom(_less_name)
	if not clean.is_empty():
		_filters[String(id_v)] = clean
	return junk


func _load_booking(e: Variant) -> bool:
	if typeof(e) != TYPE_DICTIONARY:
		return false
	var d: Dictionary = e
	var j: Variant = d.get("job_id")
	var id: Variant = d.get("building_id")
	var kg: Variant = d.get("kg")
	if typeof(j) != TYPE_STRING or String(j).is_empty() or _bookings.has(j):
		return false
	if typeof(id) != TYPE_STRING or not is_crate(id):
		return false
	if (typeof(kg) != TYPE_FLOAT and typeof(kg) != TYPE_INT) or not is_finite(float(kg)) \
			or float(kg) <= 0.0:
		return false
	_add_booking(j, id, float(kg))
	return true


# --- Internals ----------------------------------------------------------

func _on_buildings_changed(_rect: Rect2i) -> void:
	var now := {}
	for id in crate_ids():
		now[id] = true
		if not _known.has(id):
			_known[id] = true
			crates_changed.emit(id)
	var gone: Array = []
	for id: String in _known:
		if not now.has(id):
			gone.append(id)
	gone.sort_custom(_less_id)
	for id: String in gone:
		_forget(id)


func _on_building_lost(id: String, _key: StringName, _origin: Vector2i, _materials: Dictionary) -> void:
	if _known.has(id) or _filters.has(id) or _booked.has(id):
		_forget(id)


## Crate removed: drop its filter and every booking on it.
func _forget(id: String) -> void:
	_known.erase(id)
	_filters.erase(id)
	var jobs: Array = []
	for j: String in _bookings:
		if _bookings[j]["building_id"] == id:
			jobs.append(j)
	for j: String in jobs:
		release(j)
	crates_changed.emit(id)


func _add_booking(job_id: String, building_id: String, kg: float) -> void:
	_bookings[job_id] = {"building_id": building_id, "kg": kg}
	_booked[building_id] = booked_kg(building_id) + kg


## storage_kg of the building's definition; 0 if unknown or not a crate.
func _storage_kg(id: String) -> float:
	if id.is_empty():
		return 0.0
	var b: Dictionary = _buildings.call(&"get_building", id)
	if b.is_empty():
		return 0.0
	var d: Variant = _buildings.call(&"def", b.get("key", &""))
	if not (d is Object):
		return 0.0
	var v: Variant = (d as Object).get("storage_kg")
	if typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT:
		return 0.0
	var kg := float(v)
	return kg if is_finite(kg) and kg > 0.0 else 0.0


func _origin(id: String) -> Vector2i:
	var b: Dictionary = _buildings.call(&"get_building", id)
	var o: Variant = b.get("origin", Vector2i.ZERO)
	return o if typeof(o) == TYPE_VECTOR2I else Vector2i.ZERO


static func _id_num(id: String) -> int:
	return int(id.substr(id.rfind(StableIdAllocator.SEPARATOR) + 1))


## Orders ids by category, then number ("bld:2" < "bld:10").
static func _less_id(a: String, b: String) -> bool:
	var ca := StableIdAllocator.category_of(a)
	var cb := StableIdAllocator.category_of(b)
	if ca != cb:
		return String(ca) < String(cb)
	var na := _id_num(a)
	var nb := _id_num(b)
	return na < nb if na != nb else a < b


static func _less_name(a: StringName, b: StringName) -> bool:
	return String(a) < String(b)
