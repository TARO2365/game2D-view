# M2 CONTRACTS (D-019) — authoritative interfaces between agents

Every agent implements **exactly** these public names/signatures. Anything not listed is the owning
agent's private business. Changing a contract = ask the Lead (do not edit another agent's files).
All mutating calls return `CommandResult` (`src/core/command_result.gd`). All ids come from the
session's `StableIdAllocator` (`"npc:3"`, `"item:12"`, `"job:7"`, `"zone:1"`).

## 0. Coordinates and units
- Tile coords `Vector2i`, y grows **downward**. Row-major index = `y * width + x`.
- An NPC's position is its **feet tile** `F`: the NPC occupies `F`, `F+(0,-1)`, `F+(0,-2)` (3 tiles, D-003).
- Mass in kg (`float`). Time in simulation ticks (10 Hz placeholder, `SimulationClock.TICK_RATE_HZ`).

## 1. Ownership (single source of truth)
| State | Owner | Others may |
|---|---|---|
| Terrain tiles, structures (ladders) | `WorldGrid` (World Agent) | read; mutate only via `apply_edit` / `apply_structure` |
| Player orders + priorities | `DesignationMap` (Colony Agent; contract by Lead) | read |
| Item quantities and where each item is | `Inventory` (Systems Agent) | read; mutate only via Inventory methods |
| Stockpile zones + capacity bookings | `StockpileZones` (Systems Agent) | read; book/release via methods |
| Jobs, job lifecycle, **all reservations** (job↔npc, item↔job, capacity↔job) | `JobManager` (Colony Agent) | read |
| NPC intent, movement, path | `Colony` (Colony Agent) | read; commands via methods |
| Rendering, input | `src/presentation` (UI Agent) | — |
| Save composition | `src/persistence` (Lead) | each module provides snapshot functions |

Spec §3 invariant: **NPC AI never mutates Inventory or WorldGrid directly** — job steps that pick up,
deliver, dig or build are executed by `JobManager` methods that Colony calls.

## 2. World (World Agent) — additions to `WorldGrid`
```gdscript
enum Structure { NONE = 0, LADDER = 1 }
var structures: PackedByteArray            # same size as tiles, values = Structure
func get_structure(p: Vector2i) -> int
func is_ladder(p: Vector2i) -> bool
func is_passable(p: Vector2i) -> bool      # in bounds and tile is not solid (air); ladders are passable
func is_solid_at(p: Vector2i) -> bool      # out of bounds counts as solid
func can_place_structure(p: Vector2i, s: Structure) -> bool   # in bounds, air, no structure yet
func apply_structure(p: Vector2i, s: Structure) -> CommandResult   # emits tiles_changed(Rect2i(p, ONE)); marks chunk modified
func remove_structure(p: Vector2i) -> CommandResult
func terrain_hash() -> String              # sha256(tiles) only — golden hash test uses this
func world_hash() -> String                # sha256(tiles + structures)
func get_chunk_bytes(c) -> PackedByteArray # tiles then structures (2 × area bytes)
func set_chunk_bytes(c, data) -> bool      # accepts 2 × area (v2) or 1 × area (v1: structures = 0)
```
`apply_edit(.., BUILD_WALL)` fails on tiles with a structure. `TileDef` gains `drop_kg: float`
(dirt/rock/ores 50 kg PLACEHOLDER, others 0). Material key of a dug tile = its `TileDef.key`.

## 3. Inventory (Systems Agent) — `src/inventory/`
```gdscript
class_name ItemStack extends RefCounted
var id: String; var material: StringName; var kg: float
var holder: int            # Inventory.Holder
var tile: Vector2i         # valid when holder == GROUND
var holder_id: String      # npc id when NPC, job id when SITE

class_name Inventory extends RefCounted
signal items_changed(item_id: String)   # any create/move/split/consume/remove
enum Holder { GROUND = 0, NPC = 1, SITE = 2 }
const CARRY_CAPACITY_KG := 200.0       # PLACEHOLDER
func _init(ids: StableIdAllocator)
func spawn_ground(material: StringName, kg: float, tile: Vector2i) -> String     # new item id
func get_item(id: String) -> ItemStack                    # null if gone
func all_items() -> Array[ItemStack]
func items_at(tile: Vector2i) -> Array[ItemStack]          # ground items on that tile
func ground_kg_at(tile: Vector2i) -> float
func carried_by(npc_id: String) -> ItemStack              # null if hands empty
func pick_up(item_id: String, npc_id: String, max_kg: float = CARRY_CAPACITY_KG) -> CommandResult
	# ground -> npc. Splits if item.kg > max_kg (the picked part gets a NEW id; data["item_id"]).
	# fails: not on ground, npc already carrying, kg <= 0
func drop(npc_id: String, tile: Vector2i) -> CommandResult        # npc -> ground (data["item_id"])
func deliver_to_site(npc_id: String, job_id: String) -> CommandResult   # npc -> SITE(job_id)
func site_kg(job_id: String) -> float
func site_items(job_id: String) -> Array[ItemStack]
func consume_site(job_id: String) -> CommandResult         # removes site items; data["kg"]
func return_site_to_ground(job_id: String, tile: Vector2i) -> CommandResult   # cancelled build
func total_kg_by_material() -> Dictionary                   # existing items only
func spawned_kg_by_material() -> Dictionary                 # lifetime spawned
func consumed_kg_by_material() -> Dictionary                # lifetime consumed
	# Conservation invariant: spawned == total + consumed (per material, ± 0.001)
func to_snapshot() -> Dictionary
func load_snapshot(s: Dictionary) -> void
```
Inventory does **not** know reservations (JobManager owns them) and never merges stacks in M2.

**As implemented (merged 2026-10-20):** `Inventory.load_snapshot` and `StockpileZones.load_snapshot` return
`int` = entries dropped (> 0 means data loss; save loading reports it). Extra helpers:
`Inventory.check_conservation() -> Array[String]`, `StockpileZones.booked_tile(job_id)` / `booked_kg` /
`is_valid_tile` / `count`, `ConstructionDefs.accepts(kind, material)`, `ConstructionDefs.KIND_BUILD_WALL/LADDER`.
Capacity bookings are **stored** in StockpileZones but their **lifecycle** belongs to JobManager; removing a zone
tile or a terrain change silently drops its booking — JobManager must check `booked_tile(job_id)` before dropping.
`pick_up` result data: `item_id`, `kg`, `split`, `source_id`. `spawn_ground` returns `""` on invalid input.
**Added by Lead (M2 fix round):** `relocate_ground(item_id, tile) -> CommandResult` — ground → ground, same id
(item gravity). JobManager owns the gravity rule: after `tiles_changed`, ground items whose tile below is no longer
solid fall to the first tile with a solid tile directly below (never into a structure-less void forever: stop at the
world bottom).

## 4. Stockpiles (Systems Agent) — `src/inventory/stockpile_zones.gd`
```gdscript
class_name StockpileZones extends RefCounted
signal zones_changed(rect: Rect2i)
const TILE_CAPACITY_KG := 1000.0          # PLACEHOLDER
func _init(grid: WorldGrid, inventory: Inventory)
func designate(rect: Rect2i) -> CommandResult   # valid tiles: air with solid tile directly below; data["added"]
func remove(rect: Rect2i) -> CommandResult      # data["removed"]
func is_stockpile(tile: Vector2i) -> bool
func tiles() -> Array[Vector2i]
func free_capacity(tile: Vector2i) -> float     # capacity - ground kg - booked kg
func book(tile: Vector2i, kg: float, job_id: String) -> CommandResult    # reserve incoming capacity
func release(job_id: String) -> void
func find_drop_tile(kg: float, near: Vector2i) -> Vector2i   # nearest tile (Manhattan) with free_capacity >= kg, else Vector2i(-1,-1)
func is_stored(item: ItemStack) -> bool         # on GROUND inside a zone
func to_snapshot() -> Dictionary
func load_snapshot(s: Dictionary) -> void
```
Tiles that stop being valid after terrain changes are removed automatically (listen to `tiles_changed`).

## 5. Construction defs (Systems Agent) — `src/inventory/construction_defs.gd`
```gdscript
class_name ConstructionDefs extends RefCounted
static func recipe(kind: int) -> Dictionary
	# kind = DesignationMap.Kind.BUILD_WALL / BUILD_LADDER
	# {"materials": Array[StringName] accepted, "kg": float, "work_ticks": int}
	# PLACEHOLDER: wall = rock 50 kg, 30 ticks; ladder = rock or dirt 25 kg, 20 ticks
```

## 6. Orders — `DesignationMap` (contract change by Lead before M2 agents start)
```gdscript
enum Kind { NONE = 0, DIG = 1, BUILD_WALL = 2, BUILD_LADDER = 3 }
const DEFAULT_PRIORITY := 5     # 1 (lowest) .. 9 (highest)
func designate(rect: Rect2i, kind: Kind, priority: int = DEFAULT_PRIORITY) -> CommandResult
func set_priority(rect: Rect2i, priority: int) -> CommandResult
func get_priority(p: Vector2i) -> int
```

## 7. Colony + Jobs (Colony Agent) — public API used by UI and Lead
```gdscript
class_name Npc extends RefCounted
var id: String; var full_name: String; var nickname: String
var tile: Vector2i            # current feet tile
var prev_tile: Vector2i       # tile it is moving from
var move_progress: float      # 0..1 from prev_tile to tile (render interpolation)
var state: StringName         # &"idle", &"moving", &"working", &"carrying"
var job_id: String            # "" when none
var work_progress: float      # 0..1 of current work step
var work_enabled: Dictionary  # {&"dig": bool, &"build": bool, &"haul": bool}
var command_target: Vector2i  # (-1,-1) when no player move command

class_name Colony extends RefCounted
signal npcs_changed
const START_NPCS := 3
func spawn_npc(tile: Vector2i) -> Npc            # unique Thai name; uses ids + per-world RNG
func spawn_starting_npcs() -> void               # START_NPCS on the surface near world centre
func all_npcs() -> Array[Npc]
func get_npc(id: String) -> Npc
func npc_at(tile: Vector2i) -> Npc                # any NPC whose 3-tile body covers tile, else null
func command_move(npc_id: String, tile: Vector2i) -> CommandResult   # releases current job cleanly
func command_stop(npc_id: String) -> CommandResult
func set_work_enabled(npc_id: String, work: StringName, on: bool) -> CommandResult
func update(tick: int) -> void
func to_snapshot() -> Dictionary
func load_snapshot(s: Dictionary) -> void

class_name JobManager extends RefCounted
signal jobs_changed
func update(tick: int) -> void
func job_count() -> int
func describe_job(job_id: String) -> String       # e.g. "Dig (120, 40)" for the inspector
func is_unreachable(tile: Vector2i) -> bool       # order exists but no NPC can reach it (for overlay)
func check_invariants() -> Array[String]          # empty = OK (QA uses this)
func to_snapshot() -> Dictionary
func load_snapshot(s: Dictionary) -> void         # must re-validate reservations
```
`WorldSession` (Lead) constructs everything in this order and calls, per `SimulationClock.ticked`:
**1.** `jobs.update(tick)` **2.** `colony.update(tick)`.
```gdscript
var nav := NavGrid.new(grid, clearance_tiles)          # clearance from ScaleConfig (3)
var jobs := JobManager.new(grid, designations, inventory, stockpiles, nav, ids)
var colony := Colony.new(grid, nav, jobs, ids, world_seed)
```
`NavGrid` (Colony Agent, `src/navigation/nav_grid.gd`) public API:
```gdscript
func can_stand(feet: Vector2i) -> bool
func find_path(from: Vector2i, goals: Array[Vector2i], max_expansions: int = 4000) -> Array[Vector2i]  # [] = none; excludes `from`
```

## 8. Save v2 (Lead)
`save_version = 2`. Payload adds `"structures"` inside chunk bytes (2 × area), `"inventory"`,
`"stockpiles"`, `"jobs"`, `"colony"` snapshots; `"world_hash"` = `world_hash()`.
v1 → v2 migration: chunk bytes are tiles only; compare against `terrain_hash()`; empty inventory/jobs;
`colony.spawn_starting_npcs()`.

## 9. Rules for every agent
- Only edit files you own (CLAUDE.md table). Tests for your module go in `tests/unit/test_<module>_*.gd`.
- Run `powershell -File tools/run_tests.ps1` — all tests must pass before you finish. Never claim untested results.
- GDScript style: typed vars, tabs, `CommandResult` for commands, PLACEHOLDER comment on tunable numbers.
- PowerShell 5.1 corrupts UTF-8 with Get-Content/Set-Content — edit files with the Edit/Write tools only.
