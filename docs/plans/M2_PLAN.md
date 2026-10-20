# M2 PLAN — NPCs, movement, jobs, reservations, hauling

**Status:** PROPOSED — awaiting owner approval (gate G2). No M2 code until approved.
**Spec §13 M2:** NPC movement, job queue, reservations, hauling. Acceptance: no duplicate job/material claims; NPCs physically transport goods.

## 1. Scope
| # | Item | Notes |
|---|---|---|
| 1 | NPC entity | Stable id, Thai full name + nickname (no duplicates, seeded per world), placeholder body ~2.5 tiles tall (D-003), position in tiles. Starting colony: **3 NPCs** (P-1). |
| 2 | Movement rules | Stand on solid floor with 3 free tiles above (clearance standard = 3). Walk left/right, step up/down 1 tile, drop down ≤ 4 tiles, climb **ladders** (P-2). Movement advances on simulation ticks (not frames); rendering interpolates. |
| 3 | Navigation | Grid A* with movement rules above; path cache invalidated by `tiles_changed` regions only; per-tick path-search budget. |
| 4 | JobManager | Turns `DesignationMap` orders into jobs (dig, build, haul). Priority 1–9 per order (default 5, ONI-style). Jobs need a reachable work position. Unreachable jobs are marked and retried when terrain changes. |
| 5 | Reservations | Atomic claim of job + materials by exactly one NPC; released on completion, cancel, death/stop, or load. Invariant checker used in tests. |
| 6 | Digging | NPC walks to reach position, works for time based on tile hardness, tile becomes air via `WorldGrid.apply_edit` (single mutation path), drops a **material item** (dirt/rock/ore, kg). |
| 7 | Items & hauling | `Inventory` owns all item quantities: on the ground, carried by an NPC, or in a stockpile (OQ-05 → ownership by container). Player places a **Stockpile zone** (drag tool); NPCs carry loose items there. No teleporting. |
| 8 | Basic construction | Ladder and wall orders become build jobs: haul required material to the site, then build (P-3). |
| 9 | NPC control & UI | Click NPC → inspector (name, job, carrying). Quick commands: **Move here**, **Stop job** (spec §3). Per-NPC toggles for Dig / Build / Haul. Priority tool for orders. NPC names in Thai → bundled Thai font (P-4). |
| 10 | Save v2 | NPCs, items, jobs, reservations, carried items, stockpiles saved. **Migration v1 → v2** (old M1 worlds load and get the starting NPCs). Load re-validates reservations: no duplicates. |
| 11 | Stress test | 100 NPCs on a Medium world: measure tick time, path requests, FPS (spec §12). Report numbers; budgets decided from data. |

## 2. Decisions to approve
| ID | Proposal | Why |
|---|---|---|
| P-1 | Start with **3 NPCs**; more come later via events/rescue (spec §3). Debug key adds NPCs for testing. | ONI-like start; spec leaves initial count TBD. |
| P-2 | NPCs cannot climb walls: vertical travel = 1-tile steps, drops ≤ 4 tiles, and **ladders**. | Makes digging layout meaningful; matches ONI feel. |
| P-3 | **Pull basic construction (ladder + wall) into M2** from M3, using the same haul-to-site flow. M3 keeps rooms, storage buildings, doors, deconstruction. | Without ladders NPCs cannot go deep, so dig orders below would be unreachable. |
| P-4 | Bundle **Noto Sans Thai** (SIL Open Font License — free to ship) for Thai names/UI; full Thai UI translation still later (OQ-17). | Web builds cannot show Thai without a bundled font. |
| P-5 | Simulation tick stays 10 Hz placeholder; NPC walk speed ≈ 2 tiles/s at 1x (PLACEHOLDER). | Tune after stress test. |
| P-6 | Simulation determinism (same inputs ⇒ same outcome) is **not** required in M2; world generation stays deterministic. NPC names use a per-world seeded RNG. | Spec §17 TBD; full determinism is costly. |

## 3. Acceptance criteria
1. No job and no item can be claimed by two NPCs at once (unit tests + invariant check during a 10-minute simulated run).
2. Dig orders are executed by NPCs walking there; terrain changes only via `apply_edit`; one item drop per dug tile.
3. Items move only by being carried: total kg of every material is conserved across dig/haul/build/save/load.
4. NPCs reach deep dig sites via ladders built by NPCs from hauled material; unreachable jobs are shown as such, not stuck silently.
5. Move here / Stop job work and never leave orphan reservations.
6. Save/load in the middle of work (NPC carrying an item, half-dug tile, reserved job) restores without duplication or loss; M1 saves load via migration.
7. 100-NPC stress run completes; measurements reported (no hard target until owner sets one).
8. All M0/M1 tests still pass; Web smoke run passes.

## 4. Work split (D-008: separate agents, no shared files)
| Order | Agent | Files |
|---|---|---|
| 1 | **Lead** — contracts first | `src/core/` interfaces: Job, Reservation, ItemStack/container ids, Navigation query API, save v2 schema |
| 2 (parallel) | **Colony/NPC Agent** | `src/colony/`, `src/navigation/`, `src/jobs/` |
| 2 (parallel) | **Systems Agent** | `src/inventory/` (items, containers, stockpile zones, construction material requirements) |
| 2 (parallel) | **UI/UX Agent** | `src/presentation/` (NPC sprites/placeholder, inspector, tools, priority, Thai font) |
| 2 (small) | **World Agent** | ladder/wall structure tiles, dig drop data in `src/world/`, `data/defs/` |
| 3 | **Lead** — integration + `src/persistence/` v2 migration | |
| 4 | **QA Agent** — independent tests, invariant checker, stress test, Web smoke | `tests/`, `tools/` |

## 5. Out of scope (M3+)
Needs (food, sleep…), schedules, skills/traits, rooms, storage buildings, doors, deconstruction, combat, real art.
