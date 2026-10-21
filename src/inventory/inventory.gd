class_name Inventory
extends RefCounted
## Single source of truth for item quantities and where each item is
## (M2 contract §1, §3; M3 contract §4). Items lie on the ground, are carried
## by an NPC (at most one stack per NPC), sit delivered at a construction site
## or are stored in a crate building (holder CRATE, holder_id = building id).
## Crate capacity, filters and bookings live in CrateStorage, not here.
## Inventory knows nothing about reservations (JobManager owns them) and
## never merges stacks. Every change emits items_changed(item_id).
##
## Conservation invariant (per material, ± KG_EPSILON):
##     spawned_kg == total_kg + consumed_kg
##
## Queries per ground tile / site / crate use incremental indexes (M3-QA-6),
## updated by every mutation here and rebuilt by load_snapshot; kg sums are
## taken in id order so results equal a full scan bit for bit.
## verify_indexes() checks them (tests, QA).

## Emitted for every create/move/split/consume/remove of an item.
## load_snapshot() emits it once with an empty id ("everything changed").
signal items_changed(item_id: String)

enum Holder { GROUND = 0, NPC = 1, SITE = 2, CRATE = 3 }

const CARRY_CAPACITY_KG := 200.0  # PLACEHOLDER (spec §17 tuning)
const KG_EPSILON := 0.001
const ID_CATEGORY := &"item"

## Items of one ground tile, site or crate (M3-QA-6 index). The sorted list
## and the kg sum are rebuilt lazily (in id order, so results are bit-identical
## to a full scan) only after the bucket changed.
class Bucket:
	extends RefCounted
	var items: Dictionary = {}           # item id -> ItemStack
	var sorted: Array[ItemStack] = []    # valid when not dirty
	var kg: float = 0.0                  # valid when not dirty
	var dirty: bool = true


var _ids: StableIdAllocator
var _items: Dictionary = {}      # item id -> ItemStack (insertion order = creation order)
var _carried: Dictionary = {}    # npc id -> item id
var _spawned: Dictionary = {}    # StringName material -> float kg (lifetime)
var _consumed: Dictionary = {}   # StringName material -> float kg (lifetime)
# Indexes (derived, never saved; rebuilt by load_snapshot; see verify_indexes):
var _ground: Dictionary = {}     # Vector2i tile -> Bucket (GROUND items)
var _sites: Dictionary = {}      # job id -> Bucket (SITE items)
var _crates: Dictionary = {}     # building id -> Bucket (CRATE items)
var _all_sorted: Array[ItemStack] = []   # all items by id number, valid when not _all_dirty
var _all_dirty: bool = true


func _init(ids: StableIdAllocator) -> void:
	_ids = ids


# --- Queries ------------------------------------------------------------

func get_item(id: String) -> ItemStack:
	return _items.get(id)


## All existing items, ordered by id number (deterministic).
func all_items() -> Array[ItemStack]:
	if _all_dirty:
		_all_sorted.clear()
		for it: ItemStack in _items.values():
			_all_sorted.append(it)
		_all_sorted.sort_custom(_less_by_id)
		_all_dirty = false
	return _all_sorted.duplicate()


## Ground items on that tile, ordered by id number.
func items_at(tile: Vector2i) -> Array[ItemStack]:
	return _bucket_items(_ground.get(tile))


func ground_kg_at(tile: Vector2i) -> float:
	return _bucket_kg(_ground.get(tile))


func carried_by(npc_id: String) -> ItemStack:
	var id: String = _carried.get(npc_id, "")
	return _items.get(id) if not id.is_empty() else null


func site_items(job_id: String) -> Array[ItemStack]:
	return _bucket_items(_sites.get(job_id))


func site_kg(job_id: String) -> float:
	return _bucket_kg(_sites.get(job_id))


## Items stored in that crate building, ordered by id number.
func crate_items(building_id: String) -> Array[ItemStack]:
	return _bucket_items(_crates.get(building_id))


func crate_kg(building_id: String) -> float:
	return _bucket_kg(_crates.get(building_id))


func total_kg_by_material() -> Dictionary:
	var out := {}
	for it: ItemStack in _items.values():
		out[it.material] = float(out.get(it.material, 0.0)) + it.kg
	return out


func spawned_kg_by_material() -> Dictionary:
	return _spawned.duplicate()


func consumed_kg_by_material() -> Dictionary:
	return _consumed.duplicate()


## Empty array = conservation holds for every material.
func check_conservation() -> Array[String]:
	var errors: Array[String] = []
	var totals := total_kg_by_material()
	var mats := {}
	for m in _spawned:
		mats[m] = true
	for m in totals:
		mats[m] = true
	for m in _consumed:
		mats[m] = true
	for m in mats:
		var s: float = _spawned.get(m, 0.0)
		var t: float = totals.get(m, 0.0)
		var c: float = _consumed.get(m, 0.0)
		if absf(s - (t + c)) > KG_EPSILON:
			errors.append("%s: spawned %.4f != total %.4f + consumed %.4f" % [m, s, t, c])
	return errors


# --- Commands -----------------------------------------------------------

## Creates a new ground stack. Returns its id, or "" if material/kg invalid.
func spawn_ground(material: StringName, kg: float, tile: Vector2i) -> String:
	if String(material).is_empty() or not _valid_kg(kg):
		return ""
	var it := ItemStack.new()
	it.id = _ids.allocate(ID_CATEGORY)
	it.material = material
	it.kg = kg
	it.holder = Holder.GROUND
	it.tile = tile
	_items[it.id] = it
	_all_dirty = true
	_index(it)
	_spawned[material] = float(_spawned.get(material, 0.0)) + kg
	items_changed.emit(it.id)
	return it.id


## Ground -> NPC hands. If the stack is heavier than max_kg it is split:
## the picked part gets a NEW id (data["item_id"]), the rest stays.
func pick_up(item_id: String, npc_id: String, max_kg: float = CARRY_CAPACITY_KG) -> CommandResult:
	var it: ItemStack = _items.get(item_id)
	if it == null:
		return CommandResult.failure(&"unknown_item", "Item %s does not exist" % item_id)
	if npc_id.is_empty():
		return CommandResult.failure(&"invalid_npc", "No NPC given")
	if it.holder != Holder.GROUND:
		return CommandResult.failure(&"not_on_ground", "Item %s is not on the ground" % item_id)
	if _carried.has(npc_id):
		return CommandResult.failure(&"already_carrying", "%s is already carrying something" % npc_id)
	if not _valid_kg(max_kg) or not _valid_kg(it.kg):
		return CommandResult.failure(&"invalid_kg", "Nothing to pick up (kg <= 0)")
	var picked := _take(it, npc_id, max_kg)
	var split := picked != it
	if split:
		items_changed.emit(it.id)
	items_changed.emit(picked.id)
	return CommandResult.success({"item_id": picked.id, "kg": picked.kg, "split": split,
			"source_id": it.id})


## NPC hands -> ground tile.
func drop(npc_id: String, tile: Vector2i) -> CommandResult:
	var it := carried_by(npc_id)
	if it == null:
		return CommandResult.failure(&"not_carrying", "%s carries nothing" % npc_id)
	_carried.erase(npc_id)
	it.holder = Holder.GROUND
	it.holder_id = ""
	it.tile = tile
	_index(it)
	items_changed.emit(it.id)
	return CommandResult.success({"item_id": it.id, "kg": it.kg})


## Ground -> another ground tile, keeping the same id (items falling after
## the floor under them was dug). Reservations on the id stay valid.
func relocate_ground(item_id: String, tile: Vector2i) -> CommandResult:
	var it := get_item(item_id)
	if it == null:
		return CommandResult.failure(&"unknown_item", "No item %s" % item_id)
	if it.holder != Holder.GROUND:
		return CommandResult.failure(&"not_on_ground", "%s is not on the ground" % item_id)
	if it.tile == tile:
		return CommandResult.success({"item_id": it.id, "moved": false})
	_unindex(it)
	it.tile = tile
	_index(it)
	items_changed.emit(it.id)
	return CommandResult.success({"item_id": it.id, "moved": true})


## NPC hands -> construction site of job_id.
func deliver_to_site(npc_id: String, job_id: String) -> CommandResult:
	if job_id.is_empty():
		return CommandResult.failure(&"invalid_job", "No job given")
	var it := carried_by(npc_id)
	if it == null:
		return CommandResult.failure(&"not_carrying", "%s carries nothing" % npc_id)
	_carried.erase(npc_id)
	it.holder = Holder.SITE
	it.holder_id = job_id
	it.tile = Vector2i(-1, -1)
	_index(it)
	items_changed.emit(it.id)
	return CommandResult.success({"item_id": it.id, "kg": it.kg, "site_kg": site_kg(job_id)})


## Construction finished: site items are removed and counted as consumed.
func consume_site(job_id: String) -> CommandResult:
	var list := site_items(job_id)
	if list.is_empty():
		return CommandResult.failure(&"nothing_at_site", "No materials delivered to %s" % job_id)
	var total := 0.0
	var ids: Array[String] = []
	_sites.erase(job_id)
	_all_dirty = true
	for it in list:
		_items.erase(it.id)
		_consumed[it.material] = float(_consumed.get(it.material, 0.0)) + it.kg
		total += it.kg
		ids.append(it.id)
	for id in ids:
		items_changed.emit(id)
	return CommandResult.success({"kg": total, "item_ids": ids})


## Cancelled build: delivered materials go back to the ground at tile.
func return_site_to_ground(job_id: String, tile: Vector2i) -> CommandResult:
	var list := site_items(job_id)
	if list.is_empty():
		return CommandResult.failure(&"nothing_at_site", "No materials delivered to %s" % job_id)
	var total := 0.0
	var ids: Array[String] = []
	_sites.erase(job_id)
	for it in list:
		it.holder = Holder.GROUND
		it.holder_id = ""
		it.tile = tile
		_index(it)
		total += it.kg
		ids.append(it.id)
	for id in ids:
		items_changed.emit(id)
	return CommandResult.success({"kg": total, "item_ids": ids})


## NPC hands -> crate building_id. Inventory does not check capacity or
## filters: the caller books room via CrateStorage first.
func store_in_crate(npc_id: String, building_id: String) -> CommandResult:
	if building_id.is_empty():
		return CommandResult.failure(&"invalid_building", "No crate given")
	var it := carried_by(npc_id)
	if it == null:
		return CommandResult.failure(&"not_carrying", "%s carries nothing" % npc_id)
	_carried.erase(npc_id)
	it.holder = Holder.CRATE
	it.holder_id = building_id
	it.tile = Vector2i(-1, -1)
	_index(it)
	items_changed.emit(it.id)
	return CommandResult.success({"item_id": it.id, "kg": it.kg,
			"crate_kg": crate_kg(building_id)})


## Crate -> NPC hands. Split semantics identical to pick_up: if the stack is
## heavier than max_kg the taken part gets a NEW id (data["item_id"]) and the
## rest stays in the crate under the old id.
func take_from_crate(item_id: String, npc_id: String, max_kg: float = CARRY_CAPACITY_KG) -> CommandResult:
	var it: ItemStack = _items.get(item_id)
	if it == null:
		return CommandResult.failure(&"unknown_item", "Item %s does not exist" % item_id)
	if npc_id.is_empty():
		return CommandResult.failure(&"invalid_npc", "No NPC given")
	if it.holder != Holder.CRATE:
		return CommandResult.failure(&"not_in_crate", "Item %s is not in a crate" % item_id)
	if _carried.has(npc_id):
		return CommandResult.failure(&"already_carrying", "%s is already carrying something" % npc_id)
	if not _valid_kg(max_kg) or not _valid_kg(it.kg):
		return CommandResult.failure(&"invalid_kg", "Nothing to take (kg <= 0)")
	var crate_id := it.holder_id
	var taken := _take(it, npc_id, max_kg)
	var split := taken != it
	if split:
		items_changed.emit(it.id)
	items_changed.emit(taken.id)
	return CommandResult.success({"item_id": taken.id, "kg": taken.kg, "split": split,
			"source_id": it.id, "building_id": crate_id})


## Crate removed (deconstructed or lost): everything in it goes to the ground
## at tile, keeping item ids. An empty crate succeeds with kg 0.
func empty_crate_to_ground(building_id: String, tile: Vector2i) -> CommandResult:
	if building_id.is_empty():
		return CommandResult.failure(&"invalid_building", "No crate given")
	var total := 0.0
	var ids: Array[String] = []
	var list := crate_items(building_id)
	_crates.erase(building_id)
	for it in list:
		it.holder = Holder.GROUND
		it.holder_id = ""
		it.tile = tile
		_index(it)
		total += it.kg
		ids.append(it.id)
	for id in ids:
		items_changed.emit(id)
	return CommandResult.success({"kg": total, "item_ids": ids})


## Eating (M4a §4): removes kg from the stack an NPC holds and records it as
## consumed. Asking for the whole stack (within KG_EPSILON) removes the item.
## data: {item_id, kg (actually consumed), remaining_kg, removed}.
func consume_item(item_id: String, kg: float) -> CommandResult:
	var it: ItemStack = _items.get(item_id)
	if it == null:
		return CommandResult.failure(&"unknown_item", "Item %s does not exist" % item_id)
	if it.holder != Holder.NPC:
		return CommandResult.failure(&"not_carried", "Item %s is not held by an NPC" % item_id)
	if not _valid_kg(kg):
		return CommandResult.failure(&"invalid_kg", "Nothing to consume (kg <= 0)")
	if kg > it.kg + KG_EPSILON:
		return CommandResult.failure(&"not_enough", "%s has only %.3f kg" % [item_id, it.kg],
				{"available_kg": it.kg})
	var removed := kg >= it.kg - KG_EPSILON
	var eaten := it.kg if removed else kg
	_consumed[it.material] = float(_consumed.get(it.material, 0.0)) + eaten
	if removed:
		_items.erase(it.id)
		_carried.erase(it.holder_id)
		_all_dirty = true
	else:
		it.kg -= eaten
	items_changed.emit(it.id)
	return CommandResult.success({"item_id": it.id, "kg": eaten,
			"remaining_kg": 0.0 if removed else it.kg, "removed": removed})


## Production input (Kitchens.cook): consumes exactly kg of material from the
## items delivered to SITE(job_id), oldest id first; the last stack is split
## in place (keeps its id). Other materials and the rest stay at the site.
## Fails without changing anything if the site holds less than kg.
## data: {kg, item_ids (touched, ordered by id)}.
func consume_from_site(job_id: String, material: StringName, kg: float) -> CommandResult:
	if job_id.is_empty():
		return CommandResult.failure(&"invalid_job", "No job given")
	if not _valid_kg(kg):
		return CommandResult.failure(&"invalid_kg", "Nothing to consume (kg <= 0)")
	var list: Array[ItemStack] = []
	var have := 0.0
	for it in site_items(job_id):
		if it.material == material:
			list.append(it)
			have += it.kg
	if have + KG_EPSILON < kg:
		return CommandResult.failure(&"missing_input", "Site %s has %.3f kg %s, needs %.3f" % [
				job_id, have, material, kg], {"available_kg": have})
	var left := kg
	var eaten := 0.0
	var ids: Array[String] = []
	for it in list:
		if left <= KG_EPSILON:
			break
		ids.append(it.id)
		if it.kg <= left + KG_EPSILON:
			left -= it.kg
			eaten += it.kg
			_unindex(it)
			_items.erase(it.id)
			_all_dirty = true
		else:
			it.kg -= left
			eaten += left
			left = 0.0
			_touch(it)
	_consumed[material] = float(_consumed.get(material, 0.0)) + eaten
	for id in ids:
		items_changed.emit(id)
	return CommandResult.success({"kg": eaten, "item_ids": ids})


# --- Persistence --------------------------------------------------------

## Plain-typed snapshot (survives var_to_bytes / bytes_to_var).
func to_snapshot() -> Dictionary:
	var items: Array = []
	for it in all_items():
		items.append({
			"id": it.id,
			"material": String(it.material),
			"kg": it.kg,
			"holder": it.holder,
			"tile": it.tile,
			"holder_id": it.holder_id,
		})
	return {"items": items, "spawned": _ledger_out(_spawned), "consumed": _ledger_out(_consumed)}


## Restores from a snapshot, skipping invalid entries (never crashes).
## The spawned ledger is rebuilt as total + consumed so conservation holds
## even when junk entries were dropped. Returns the number of dropped
## entries: callers (save loading, QA) must treat > 0 as material loss.
func load_snapshot(s: Dictionary) -> int:
	_items.clear()
	_carried.clear()
	_spawned.clear()
	_consumed.clear()
	_ground.clear()
	_sites.clear()
	_crates.clear()
	_all_sorted.clear()
	_all_dirty = true
	var dropped := 0
	var items_v: Variant = s.get("items")
	if typeof(items_v) == TYPE_ARRAY:
		for e: Variant in items_v:
			var it := _item_from(e)
			if it == null or _items.has(it.id):
				dropped += 1
				continue
			if it.holder == Holder.NPC:
				if _carried.has(it.holder_id):
					dropped += 1
					continue  # one stack per NPC
				_carried[it.holder_id] = it.id
			_items[it.id] = it
			_index(it)
	_consumed = _ledger_in(s.get("consumed"))
	var totals := total_kg_by_material()
	for m in totals:
		_spawned[m] = float(totals[m])
	for m in _consumed:
		_spawned[m] = float(_spawned.get(m, 0.0)) + float(_consumed[m])
	items_changed.emit("")
	return dropped


func _item_from(e: Variant) -> ItemStack:
	if typeof(e) != TYPE_DICTIONARY:
		return null
	var d: Dictionary = e
	var id_v: Variant = d.get("id")
	var mat_v: Variant = d.get("material")
	var kg_v: Variant = d.get("kg")
	var holder_v: Variant = d.get("holder")
	var tile_v: Variant = d.get("tile", Vector2i(-1, -1))
	var hid_v: Variant = d.get("holder_id", "")
	if typeof(id_v) != TYPE_STRING or not StableIdAllocator.is_valid(id_v) \
			or StableIdAllocator.category_of(id_v) != ID_CATEGORY:
		return null
	if typeof(mat_v) != TYPE_STRING and typeof(mat_v) != TYPE_STRING_NAME:
		return null
	if String(mat_v).is_empty():
		return null
	if typeof(kg_v) != TYPE_FLOAT and typeof(kg_v) != TYPE_INT:
		return null
	if not _valid_kg(float(kg_v)):
		return null
	if typeof(holder_v) != TYPE_INT or not (holder_v in [Holder.GROUND, Holder.NPC, Holder.SITE, Holder.CRATE]):
		return null
	if typeof(tile_v) != TYPE_VECTOR2I or typeof(hid_v) != TYPE_STRING:
		return null
	var it := ItemStack.new()
	it.id = id_v
	it.material = StringName(mat_v)
	it.kg = float(kg_v)
	it.holder = holder_v
	if it.holder == Holder.GROUND:
		it.tile = tile_v
		it.holder_id = ""
	else:
		if String(hid_v).is_empty():
			return null
		it.holder_id = hid_v
	return it


## Moves it (or a max_kg split of it, with a new id) into npc_id's hands and
## returns the stack now carried. Callers validate first and emit signals.
func _take(it: ItemStack, npc_id: String, max_kg: float) -> ItemStack:
	var picked := it
	if it.kg > max_kg + KG_EPSILON:
		picked = ItemStack.new()
		picked.id = _ids.allocate(ID_CATEGORY)
		picked.material = it.material
		picked.kg = max_kg
		it.kg -= max_kg
		_touch(it)
		_items[picked.id] = picked
		_all_dirty = true
	else:
		_unindex(it)
	picked.holder = Holder.NPC
	picked.holder_id = npc_id
	picked.tile = Vector2i(-1, -1)
	_carried[npc_id] = picked.id
	return picked


## Debug consistency check of the derived indexes against _items (tests and
## QA call it after random walks). Empty array = every index is consistent.
func verify_indexes() -> Array[String]:
	var errors: Array[String] = []
	var expect := {}   # "g|tile" / "s|job" / "c|bld" -> {item id: true}
	for it: ItemStack in _items.values():
		if it.holder == Holder.NPC:
			if _carried.get(it.holder_id, "") != it.id:
				errors.append("%s held by %s but _carried says %s" % [it.id, it.holder_id,
						_carried.get(it.holder_id, "")])
			continue
		var key := _debug_key(it.holder, it.tile if it.holder == Holder.GROUND else it.holder_id)
		if not expect.has(key):
			expect[key] = {}
		expect[key][it.id] = true
	for npc: String in _carried:
		var c: ItemStack = _items.get(_carried[npc])
		if c == null or c.holder != Holder.NPC or c.holder_id != npc:
			errors.append("_carried[%s] = %s is stale" % [npc, _carried[npc]])
	var seen := 0
	for pair: Array in [[Holder.GROUND, _ground], [Holder.SITE, _sites], [Holder.CRATE, _crates]]:
		var index: Dictionary = pair[1]
		for k: Variant in index:
			var b: Bucket = index[k]
			var key := _debug_key(pair[0], k)
			seen += 1
			if b.items.is_empty():
				errors.append("empty bucket %s" % key)
				continue
			var want: Dictionary = expect.get(key, {})
			if want.size() != b.items.size():
				errors.append("bucket %s has %d items, expected %d" % [key, b.items.size(), want.size()])
			for id: String in b.items:
				if not want.has(id) or _items.get(id) != b.items[id]:
					errors.append("bucket %s holds stale %s" % [key, id])
			var list := _bucket_items(b)
			if list.size() != b.items.size():
				errors.append("bucket %s cached list is stale" % key)
			var sum := 0.0
			for i in list.size():
				sum += list[i].kg
				if i > 0 and not _less_by_id(list[i - 1], list[i]):
					errors.append("bucket %s not sorted by id" % key)
			if sum != b.kg:
				errors.append("bucket %s kg %.6f != %.6f" % [key, b.kg, sum])
	if seen != expect.size():
		errors.append("%d buckets, expected %d" % [seen, expect.size()])
	var all := all_items()
	if all.size() != _items.size():
		errors.append("all_items has %d, expected %d" % [all.size(), _items.size()])
	for i in range(1, all.size()):
		if not _less_by_id(all[i - 1], all[i]):
			errors.append("all_items not sorted at %d" % i)
			break
	return errors


func _debug_key(holder: int, k: Variant) -> String:
	return "%d|%s" % [holder, k]


func _index_of(holder: int) -> Variant:
	match holder:
		Holder.GROUND:
			return _ground
		Holder.SITE:
			return _sites
		Holder.CRATE:
			return _crates
	return null


func _index(it: ItemStack) -> void:
	var index: Variant = _index_of(it.holder)
	if index == null:
		return
	var key: Variant = it.tile if it.holder == Holder.GROUND else it.holder_id
	var b: Bucket = (index as Dictionary).get(key)
	if b == null:
		b = Bucket.new()
		index[key] = b
	b.items[it.id] = it
	b.dirty = true


func _unindex(it: ItemStack) -> void:
	var index: Variant = _index_of(it.holder)
	if index == null:
		return
	var key: Variant = it.tile if it.holder == Holder.GROUND else it.holder_id
	var b: Bucket = (index as Dictionary).get(key)
	if b == null:
		return
	b.items.erase(it.id)
	if b.items.is_empty():
		(index as Dictionary).erase(key)
	else:
		b.dirty = true


## The item's kg changed in place (split): its bucket's sum is stale.
func _touch(it: ItemStack) -> void:
	var index: Variant = _index_of(it.holder)
	if index == null:
		return
	var b: Bucket = (index as Dictionary).get(it.tile if it.holder == Holder.GROUND else it.holder_id)
	if b != null:
		b.dirty = true


func _refresh(b: Bucket) -> void:
	if not b.dirty:
		return
	b.sorted.clear()
	for it: ItemStack in b.items.values():
		b.sorted.append(it)
	b.sorted.sort_custom(_less_by_id)
	b.kg = 0.0
	for it in b.sorted:
		b.kg += it.kg
	b.dirty = false


func _bucket_items(b: Bucket) -> Array[ItemStack]:
	if b == null:
		var none: Array[ItemStack] = []
		return none
	_refresh(b)
	return b.sorted.duplicate()


func _bucket_kg(b: Bucket) -> float:
	if b == null:
		return 0.0
	_refresh(b)
	return b.kg


static func _ledger_out(src: Dictionary) -> Dictionary:
	var out := {}
	for m in src:
		out[String(m)] = float(src[m])
	return out


static func _ledger_in(v: Variant) -> Dictionary:
	var out := {}
	if typeof(v) != TYPE_DICTIONARY:
		return out
	var d: Dictionary = v
	for k: Variant in d:
		var val: Variant = d[k]
		if (typeof(k) != TYPE_STRING and typeof(k) != TYPE_STRING_NAME) or String(k).is_empty():
			continue
		if typeof(val) != TYPE_FLOAT and typeof(val) != TYPE_INT:
			continue
		if not _valid_kg(float(val)):
			continue
		out[StringName(k)] = float(val)
	return out


static func _valid_kg(kg: float) -> bool:
	return is_finite(kg) and kg > 0.0


static func _id_num(id: String) -> int:
	return int(id.substr(id.rfind(StableIdAllocator.SEPARATOR) + 1))


static func _less_by_id(a: ItemStack, b: ItemStack) -> bool:
	return _id_num(a.id) < _id_num(b.id)
