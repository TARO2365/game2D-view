# M4a CONTRACTS (D-028) — time, schedules, needs, food, alerts

Extends M2/M3 contracts (ownership, CommandResult, stable ids, plain-type snapshots that return dropped counts,
no cross-module mutation). Approved plan: `docs/plans/M4_PLAN.md` (P-1…P-6). All numbers are PLACEHOLDER.

## 1. Ownership additions
| State | Owner |
|---|---|
| Time of day (derived from `SimulationClock.tick_index`, never saved separately) | `GameTime` — Lead (`src/core/game_time.gd`) |
| Alerts (derived each tick from world state; not saved) | `AlertService` — Lead (`src/core/alert_service.gd`) |
| Material definitions incl. food (display name, colour, category, nutrition) | `MaterialDefs` — Systems (`src/inventory/material_defs.gd`, `data/defs/materials.tres`) |
| Crop state per farm plot; kitchen production state/targets | `Farming`, `Kitchens` — Systems (`src/inventory/farming.gd`, `kitchens.gd`) |
| Farm plot / kitchen building defs | World (`data/defs/buildings.tres`) |
| NPC needs, schedules, bed ownership, collapse/death, need-driven behaviour, farm/cook/eat jobs | Colony Agent (`src/colony`, `src/jobs`) |

## 2. GameTime (Lead)
```gdscript
class_name GameTime extends RefCounted
const TICKS_PER_DAY := 6000          # 10 real minutes at 1x (P-4)
const TICKS_PER_HOUR := 250
static func day(tick: int) -> int            # 1-based
static func hour(tick: int) -> int           # 0..23
static func minute(tick: int) -> int         # 0..59
static func is_night(tick: int) -> bool      # 20:00–06:00 (visual only in M4a)
static func label(tick: int) -> String       # "Day 3  14:20"
```

## 3. AlertService (Lead)
```gdscript
class_name AlertService extends RefCounted
signal alerts_changed
enum Severity { GENERAL = 0, IMPORTANT = 1, EMERGENCY = 2 }
func set_alert(key: String, severity: Severity, message: String, tile: Vector2i = Vector2i(-1,-1), npc_id: String = "") -> void
func clear(key: String) -> void
func clear_prefix(prefix: String) -> void
func alerts() -> Array[Dictionary]   # sorted: severity desc, then key; {key, severity, message, tile, npc_id, since_tick}
```
Producers own their keys (`"npc:3/hungry"`, `"colony/no_food"`). Not saved: producers re-raise after load.

## 4. Materials & food (Systems)
`MaterialDefs`: `def(material: StringName) -> Dictionary` `{key, display_name, color, category: &"soil"|&"ore"|&"food", nutrition_per_kg: float}`;
`all_keys()`, `foods() -> Array[StringName]`. Food materials: `&"mushroom"` (raw, nutrition 25/kg), `&"meal"` (60/kg),
`&"ration"` (50/kg). Existing tile materials get entries (category soil/ore, nutrition 0).
Inventory addition: `consume_item(item_id: String, kg: float) -> CommandResult` — removes kg from an item held by an
NPC (eating) and records it in the consumed ledger (conservation still holds).

## 5. Farming & kitchens (Systems)
```gdscript
class_name Farming extends RefCounted     # one crop per farm_plot building
signal farms_changed(building_id: String)
enum Stage { EMPTY = 0, GROWING = 1, READY = 2 }
const GROW_TICKS := 6000                  # one day
const YIELD_KG := 6.0                     # mushroom per harvest
func _init(buildings, inventory, ids)     # tracks farm_plot buildings via buildings signals
func stage(building_id: String) -> int
func progress(building_id: String) -> float        # 0..1
func plant(building_id: String) -> CommandResult   # EMPTY -> GROWING (called by JobManager when the farmer works)
func harvest(building_id: String, drop_tile: Vector2i) -> CommandResult  # READY -> EMPTY, spawns mushroom item; data["item_id"]
func update(tick: int) -> void                     # grows crops
func to_snapshot() -> Dictionary
func load_snapshot(s: Dictionary) -> int

class_name Kitchens extends RefCounted
const RECIPE := {"input": &"mushroom", "input_kg": 2.0, "output": &"meal", "output_kg": 2.0, "work_ticks": 60}
func _init(buildings, inventory)
func target_kg(building_id: String) -> float        # keep this much meal in storage colony-wide (default 10)
func set_target_kg(building_id: String, kg: float) -> CommandResult
func needs_cooking(total_meal_kg: float, building_id: String) -> bool
func cook(building_id: String, job_id: String, drop_tile: Vector2i) -> CommandResult  # consumes SITE(job) input, spawns output; data["item_id"]
func to_snapshot() -> Dictionary
func load_snapshot(s: Dictionary) -> int
```
Cooking uses the M3 site flow: JobManager hauls `input_kg` mushroom to `SITE(job_id)`, works `work_ticks`, then `cook`.

## 6. Buildings (World)
`farm_plot` 2×1 (dirt 50 kg, 20 ticks, needs a **dirt or rock floor**, room_tag &"farm"), `kitchen` 2×1 (rock 100 kg,
40 ticks, room_tag &"kitchen"). Room types gain farm/kitchen (priority after bedroom: bedroom > kitchen > dining > storage > farm > room).

## 7. Colony: needs, schedules, behaviour (Colony Agent)
`Npc` gains: `hunger` (100 = full, eats below 40), `stamina` (100 = rested; sleeps when schedule says Sleep or below 15),
`health` (drops while hunger = 0 or stamina = 0, recovers otherwise), `condition: StringName` (&"ok", &"collapsed",
&"dead"), `schedule: PackedByteArray` (24 × Activity {WORK=0, SLEEP=1, FREE=2}), `bed_id: String`.
Rates (PLACEHOLDER): hunger −100/day, stamina −100/16 h awake, +100/6 h in bed (+50 % in a bedroom), ×0.5 on the floor.
Collapse when health reaches 0 → `collapsed` (no work, emergency alert); **dies after 6000 ticks collapsed** unless
health recovers > 20 (P-2); others may feed a collapsed NPC (job *Feed*). Death: drops carried items, body removed
(M9 adds mourning), alert. Need behaviour pre-empts jobs cleanly (release reservations as in M2).
`Colony` API additions:
```gdscript
func set_schedule(npc_id: String, hours: PackedByteArray) -> CommandResult
func set_schedule_all(hours: PackedByteArray) -> CommandResult
func assign_bed(npc_id: String, bed_id: String) -> CommandResult   # "" = auto
```
JobManager adds kinds *Farm* (plant/harvest), *Cook*, *Feed*; eating and sleeping are NPC activities, not jobs, but
food items are reserved through JobManager like any item. Refuse unsafe commands (spec §3): collapsed NPCs refuse
`command_move` and work; critically hungry (< 10) NPCs refuse work orders until fed.

## 8. Session & save (Lead)
`WorldSession` adds `alerts`, `materials`, `farming`, `kitchens`; tick order: `farming.update`, `jobs.update`,
`colony.update`, then alert refresh. New world: starting crate with 20 kg `ration` (P-6). Save v4 adds `farming`,
`kitchens`; colony/jobs snapshots carry needs/schedules/new jobs. v3 → v4: NPCs start fed/rested, default schedules.
