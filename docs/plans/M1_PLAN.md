# M1 PLAN — Tiles, seeded world, chunks, camera, dig/build, basic save/load

**Status:** PROPOSED — awaiting owner approval (gate G2). No M1 code is written until approved.
**Roles (D-008, sequential):** Lead (contracts, persistence) → World → UI/UX → QA.

## 1. Scope
| # | Item | Notes |
|---|---|---|
| 1 | Tile definitions | `data/defs/tiles/*.tres`: air, dirt, rock, iron_ore, gold_ore, crystal, bedrock (world border), concrete (player-built wall). Placeholder colors generated at runtime — no art files. |
| 2 | Finite world data `WorldGrid` | Whole world held in memory (one byte per tile per layer — 512×256 ≈ 128 KB), so **simulation never depends on the camera**. Chunk = 32×32 tiles (placeholder). |
| 3 | Seeded generator `WorldGenerator` | Surface line with hills, dirt band, rock below, ore veins by depth, bedrock border. Deterministic from `seed` + `GEN_VERSION = 1`. **No caves** (M7). |
| 4 | Tile edit command + dirty events | `WorldGrid.apply_edit(rect, new_type) -> CommandResult`; emits `tiles_changed(rect)` so later systems (nav, rooms, stability) update only affected regions. |
| 5 | Chunk renderer (visual streaming) | One `TileMapLayer` per visible chunk (+1 margin), created/freed as the camera moves; edits redraw only the affected chunks. |
| 6 | Camera | Pan: WASD/arrows, middle-mouse drag, one-finger drag (touch). Zoom: wheel, pinch (touch), +/- buttons. Clamped to world bounds. Zoom 0.25×–2× (placeholder). |
| 7 | Tools + drag-select | Toolbar: Select / Dig / Build wall / Cancel. Drag a rectangle → preview → apply. UI only issues commands and displays `CommandResult` messages. |
| 8 | Save/load (D-007, D-014) | `user://worlds/<world_id>/` with `meta.json`, `manual.save`, `autosave.save`, `.bak`. Max 3 stored worlds, one loaded at a time. Saves seed + gen version + **only changed chunks** + clock + id allocator. Atomic write (tmp → verify → rotate .bak → rename). Corrupt file → fall back to .bak with a clear message. |
| 9 | Main menu | New World (optional seed, world size), Continue/Load list (name, created, last played), Delete (confirmation). New World disabled at 3 worlds with explanation. In-game: Save button + Ctrl+S, autosave every 5 real minutes (placeholder) at a tick boundary, Quit to menu. |
| 10 | Debug HUD | FPS, tick, tick ms, world hash, chunk count drawn, cursor tile coordinate/type. |

## 2. Decisions to approve with this plan
| ID | Proposal | Why |
|---|---|---|
| P-1 | **Dig/build are instant in M1** and cost nothing. They are temporary "designation applied immediately"; M2 replaces them with NPC jobs + hauling (spec §3: no teleporting materials). | No NPCs/inventory exist yet; M1 must still prove edit → render → save works. |
| P-2 | World sizes: Small 384×192, **Medium 512×256 (default)**, Large 1024×384 tiles. Final values after profiling. | Spec §17 TBD; gives benchmark data early. |
| P-3 | Soft fog of war deferred to M7 (with exploration/caves). | Not assigned to any milestone in spec §13. |
| P-4 | Save format: `meta.json` (human-readable) + compressed binary payload (`FileAccess.open_compressed`, `store_var`) with `save_version = 1`. | Small files, fast load, versioned. |
| P-5 | Load with mismatched `GEN_VERSION` is refused with a clear message (no migration yet). | Migration strategy starts when the generator changes. |
| P-6 | Min spec (D-012): PC Windows 10/11 64-bit with OpenGL 3.3; Web: current desktop Chrome/Edge/Firefox; mobile browser: Android Chrome (best effort); iOS Safari "untested" until a device is available. | Needed before M1 closes. |
| P-7 | World name auto-generated ("World 1…3" + seed); rename deferred (OQ-16). | Keeps scope small. |

## 3. Acceptance criteria
1. Same seed + gen version ⇒ identical world hash (tested); different seeds ⇒ different hash.
2. Medium world generates in **< 2 s** on this PC (measured; reported either way).
3. Dig/build commands validate: out of bounds, bedrock, digging air, building into solid ⇒ failure `CommandResult` with message; nothing changes.
4. An edit emits exactly one `tiles_changed` with the correct rect, and only affected chunks redraw (tested).
5. Pan/zoom works with mouse, keyboard and touch emulation; camera never leaves world bounds.
6. Save → quit → load reproduces identical terrain hash, clock tick and id allocator state (round-trip test).
7. Save is atomic: an interrupted write (simulated) leaves the previous save loadable; a corrupt file falls back to `.bak`.
8. Max 3 worlds enforced; deleting frees a slot; only one world loaded at a time.
9. Web build: generate, dig, save, reload page, continue — works in browser (IndexedDB). Golden hash on Web equals PC hash (OQ-06).
10. All M0 tests still pass (regression).

## 4. Out of scope (M2+)
NPCs, jobs, hauling, materials/inventory, construction cost, ladders/navigation, rooms, caves, fog of war,
stability/collapse, any production art.

## 5. Risks
- `TileMapLayer` churn while panning fast → mitigate with chunk pooling; measure.
- FastNoiseLite float differences on WASM → golden hash test (criterion 9); if it fails, switch to integer noise.
- Browser storage quota × 3 worlds (OQ-07) → measure save size; Medium save target < 1 MB.
- Touch pan vs drag-select conflict → tool mode decides (Select tool pans; Dig/Build drags select).

## 6. Expected files (ownership)
`src/world/` (World): `tile_def.gd`, `tile_registry.gd`, `world_grid.gd`, `world_generator.gd`, `chunk_math.gd`
`src/persistence/` (Lead): `world_slots.gd`, `save_service.gd`
`src/presentation/` (UI): `world_view.gd` (chunk renderer), `camera_controller.gd`, `tool_controller.gd`, `ui/toolbar.gd`, `ui/main_menu.gd`, `ui/debug_hud.gd`
`scenes/`: `main_menu.tscn`, `game.tscn`
`data/defs/tiles/*.tres`, `data/config/world_presets.tres`
`tests/unit/` + `tests/integration/` (QA)
