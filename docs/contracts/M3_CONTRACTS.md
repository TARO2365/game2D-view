# M3 CONTRACTS (D-022) — buildings, doors, storage crates, rooms, deconstruction

Extends `M2_CONTRACTS.md` (all M2 rules still apply: ownership, CommandResult, stable ids, plain-type snapshots,
`load_snapshot` returns dropped count, no direct cross-module mutation). Changing a contract = ask the Lead.

## 1. Ownership additions
| State | Owner |
|---|---|
| Building definitions (`data/defs/buildings.tres`) and placed building instances + tile occupancy | `Buildings` — World Agent (`src/world/buildings.gd`, `building_def.gd`) |
| Rooms (derived, recomputed, never saved) | `RoomMap` — World Agent (`src/world/room_map.gd`) |
| Items inside crates, crate filters, crate capacity bookings | `Inventory` (holder CRATE) + `CrateStorage` — Systems Agent (`src/inventory/crate_storage.gd`) |
| Building orders, deconstruct orders → jobs, all reservations | `BuildOrders` (`src/jobs/build_orders.gd`) + `JobManager` — Colony Agent |
| Art: spec, prompts, art loader, procedural (B) art | Asset Agent (D-020) |

## 2. Buildings (World Agent)
```gdscript
class_name BuildingDef extends Resource
@export var key: StringName            # &"door", &"crate", &"bed", &"table"  (saved: never rename)
@export var display_name: String
@export var size: Vector2i             # tiles; origin = bottom-left tile
@export var materials: Array[StringName]  # accepted materials (any one)
@export var kg: float                  # PLACEHOLDER
@export var work_ticks: int            # PLACEHOLDER
@export var needs_floor: bool = true   # every tile under the bottom row must be solid
@export var is_door: bool = false      # passable, but a room boundary
@export var storage_kg: float = 0.0    # > 0 = crate
@export var room_tag: StringName = &"" # &"bedroom" (bed), &"storage" (crate), &"dining" (table)
```
PLACEHOLDER defs: door 1×3 (rock 50 kg, 30 ticks, is_door; must stand in a 1-wide gap: solid tile above the top
and needs_floor), crate 1×1 (rock or dirt 50 kg, 20 ticks, storage_kg 2000, room_tag storage), bed 2×1 (rock or dirt
50 kg, 30 ticks, bedroom), table 2×1 (rock 50 kg, 30 ticks, dining).
```gdscript
class_name Buildings extends RefCounted
signal buildings_changed(rect: Rect2i)        # placed / removed (rect = footprint)
signal building_lost(id: String, key: StringName, origin: Vector2i, materials: Dictionary)  # lost support
func _init(grid: WorldGrid, ids: StableIdAllocator)   # ids category &"bld"
func def(key: StringName) -> BuildingDef
func footprint(key: StringName, origin: Vector2i) -> Rect2i
func can_place(key: StringName, origin: Vector2i) -> CommandResult   # every tile air, no structure, no building; floor/door rules
func place(key: StringName, origin: Vector2i, materials: Dictionary) -> CommandResult   # data["id"]; emits tiles_changed too
func remove(id: String) -> CommandResult      # data["materials"] (material -> kg used to build it)
func get_building(id: String) -> Dictionary   # {id, key, origin, materials} or {}
func building_at(tile: Vector2i) -> String    # id or ""
func all_ids() -> Array[String]
func is_door(tile: Vector2i) -> bool
func to_snapshot() -> Dictionary
func load_snapshot(s: Dictionary) -> int
```
Rules: buildings sit in **air tiles**; they do not block NPC movement (furniture is walk-through, doors are passable).
`WorldGrid.apply_edit(BUILD_WALL)` and `apply_structure` must fail on building tiles (World Agent adds
`grid.set_occupancy_query(callable)` or equivalent so the grid can ask Buildings). After `tiles_changed`, a building
whose floor (or door's top support) is gone is removed and `building_lost` is emitted — JobManager drops its
materials on the ground (100 % refund, D-021).
`WorldGrid` gains `Edit.DECONSTRUCT_WALL` (CONCRETE → AIR only).

## 3. Rooms (World Agent)
```gdscript
class_name RoomMap extends RefCounted
signal rooms_changed(rect: Rect2i)
const MAX_ROOM_TILES := 128   # PLACEHOLDER (D-021)
func _init(grid: WorldGrid, buildings: Buildings)
func room_at(tile: Vector2i) -> Dictionary  # {} if none; else {id: int (runtime only), type: StringName, size: int, bounds: Rect2i, building_ids: Array[String]}
func all_rooms() -> Array[Dictionary]
```
A room = 4-connected set of non-solid, non-door tiles, bounded by solid tiles / door tiles, size ≤ MAX_ROOM_TILES,
not touching the world border or a tile above the surface line (open sky). Type: first match of
bedroom (has bed) > storage (has crate) > dining (has table) > &"room". Recompute only regions touched by
`tiles_changed` / `buildings_changed` (bounded flood fills). Rooms are NOT saved; they are rebuilt on load.

## 4. Crates (Systems Agent)
`Inventory.Holder.CRATE = 3` (holder_id = building id). New Inventory methods:
```gdscript
func store_in_crate(npc_id: String, building_id: String) -> CommandResult     # npc -> crate
func take_from_crate(item_id: String, npc_id: String, max_kg: float = CARRY_CAPACITY_KG) -> CommandResult  # crate -> npc (split like pick_up)
func crate_items(building_id: String) -> Array[ItemStack]
func crate_kg(building_id: String) -> float
func empty_crate_to_ground(building_id: String, tile: Vector2i) -> CommandResult  # crate removed
```
```gdscript
class_name CrateStorage extends RefCounted
signal crates_changed(building_id: String)
func _init(buildings: Buildings, inventory: Inventory)
func crate_ids() -> Array[String]
func set_filter(building_id: String, materials: Array[StringName]) -> CommandResult   # [] = accept all
func get_filter(building_id: String) -> Array[StringName]
func accepts(building_id: String, material: StringName) -> bool
func free_capacity(building_id: String) -> float     # storage_kg - crate_kg - booked
func book(building_id: String, kg: float, job_id: String) -> CommandResult
func release(job_id: String) -> void
func booked_crate(job_id: String) -> String
func find_crate(material: StringName, kg: float, near: Vector2i) -> String   # nearest accepting crate with room, "" if none
func is_stored(item: ItemStack) -> bool   # holder CRATE
func to_snapshot() -> Dictionary
func load_snapshot(s: Dictionary) -> int
```
`StockpileZones.is_stored` stays; "stored" overall = in a crate OR on a stockpile tile.

## 5. Orders (Lead adds to DesignationMap before agents start)
`DesignationMap.Kind.DECONSTRUCT = 4` — valid on CONCRETE tiles, ladder tiles and building tiles.
Building placement orders are multi-tile, so they live in **`BuildOrders`** (Colony Agent, `src/jobs/build_orders.gd`):
```gdscript
signal orders_changed(rect: Rect2i)
func order_building(key: StringName, origin: Vector2i, priority: int = 5) -> CommandResult   # uses Buildings.can_place + no overlap with other orders/designations
func cancel_at(rect: Rect2i) -> CommandResult
func orders() -> Array[Dictionary]   # {id, key, origin, priority}
func order_at(tile: Vector2i) -> Dictionary
func to_snapshot() -> Dictionary
func load_snapshot(s: Dictionary) -> int
```
JobManager: build jobs for building orders (haul materials to the site → work → `buildings.place`), deconstruct jobs
(walls: `apply_edit(DECONSTRUCT_WALL)` + drop recipe kg; ladders: `remove_structure` + drop recipe kg; buildings:
`buildings.remove` + drop returned materials; crates: `empty_crate_to_ground` first), haulers prefer
`crate_storage.find_crate` over stockpile zones, build material may come from crates.

## 6. Session wiring (Lead) — construction order
```gdscript
buildings = Buildings.new(grid, ids)
rooms = RoomMap.new(grid, buildings)
crates = CrateStorage.new(buildings, inventory)
build_orders = BuildOrders.new(grid, buildings, designations, ids)
jobs = JobManager.new(...)   # Colony Agent may extend its constructor; Lead wires it
```
Save v3: adds `buildings`, `crates`, `build_orders`; inventory with CRATE holders; v2 → v3 migration = empty.
Load order: designations, buildings, inventory, stockpiles, crates, build_orders, colony, jobs; rooms rebuilt last.
