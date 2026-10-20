# M3 QA REPORT — independent verification of rooms, buildings, crates, deconstruction

QA Agent, 2026-10-21, on main `665806d` (M3 World/Systems/Colony/UI + Art V1) merged into the QA branch.
Implementation files were not modified. Every bug below has a test that was confirmed FAILING before `pending()`.

## 1. What QA added / changed
| File | Purpose |
|---|---|
| `tools/qa_harness.gd` | Lead (b): priority check now per job kind — building jobs vs their `BuildOrders` priority, dig/build/deconstruct vs the tile designation (a building deconstruct job uses its main tile). New `m3_invariants` (buildings on air/no ladder with support and exact recipe kg, occupancy, crate kg ≤ capacity incl. bookings, bookings only on crates, building orders still placeable and not overlapping designations), `rooms_vs_rebuild` (incremental rooms == fresh full rebuild), M3 random actions (`enable_m3`: building orders, deconstruct, cancel/priority of building orders, crate filters, rooms carved underground, floors dug under buildings), save/load comparator extended with buildings, build orders, crate filters, crate kg and **rooms** (lead c) |
| `tools/qa_m3_env.gd` | Hand-made-grid `WorldSession` + v3 save/load in exactly `SaveService.session_from_payload` order (incl. orphan rescue, rooms rebuilt last) |
| `tools/qa_stress.gd` | 5th arg `m3`: M3 actions + rooms vs rebuild every 50 ticks |
| `tools/qa_bench.gd` | Scenario C: 100-NPC base, 30 door-closed rooms, 60 crates, 30 beds, 2000 stacks (+ the same base with zones instead of crates) + room update cost |
| `tests/qa/test_qa_m3_buildings.gd` | Criteria 1, 2, 5, 6 |
| `tests/qa/test_qa_m3_crates.gd` | Criterion 4, lead (a) |
| `tests/qa/test_qa_m3_rooms.gd` | Criterion 3 (NPC-driven, every edit kind), lead (c) |
| `tests/qa/test_qa_m3_save.gd` | Criterion 7 |
| `tests/qa/test_qa_m3_ui.gd` | Criterion 8 |
| `tests/stress/test_qa_m3_stress.gd` | In-suite M3 random stress (3 seeds × 3000 ticks) |

## 2. Suites (executed)
- `tools/run_tests.ps1` → exit 0: **Scripts 51, Tests 425, Passing 419, Pending 6, Failing 0**, Asserts 5037
  (main before QA: 396/396). Pending = M3-QA-1, M3-QA-2 (×2), M3-QA-3, M3-QA-4, M3-QA-5.
- `tools/run_stress.ps1` → exit 0: **7/7 passed** (4 M2 + 3 M3 stress tests); no leak warning.
- Long run `qa_stress.gd -- 20000 5 1 8 m3` → **RESULT OK** (§4).

## 3. Acceptance table (written by QA from M3_PLAN §1/§3)
| # | Criterion | Result | Evidence |
|---|---|---|---|
| 1 | Buildings only from hauled material, kg conserved | **PASS** | `test_buildings_and_wall_refund_exactly_per_material`: crate, bed, table, door + wall from 400 kg rock + 400 kg dirt; ground + locked-in-buildings + wall = start, every building holds exactly its recipe kg; `test_order_without_material_never_builds`; QA invariant "building materials == recipe kg" every tick in all stress runs; Web: crate holds exactly 300 dug − 100 built + 50 refund = 250 kg |
| 2 | Door / crate / bed / table placement rules | **PASS** | `test_placement_rules`: floor under every bottom tile, no ladder/solid/out of bounds, door needs a solid tile above (2-wide gaps allowed, D-023), no overlap, crate is not a floor, walls/ladders/wall+ladder orders refused on building tiles, wrong material refused |
| 3 | Rooms on every kind of edit; incremental == full rebuild | **PASS** | `test_rooms_follow_every_kind_of_npc_edit`: through NPC jobs — door closes a pocket (24 tiles), bed → bedroom, crate (bed wins), inner door splits 9/12 (bedroom/storage), wall shrinks 12→11, deconstruct wall restores, dig grows 13, deconstruct door merges 25, buildings lost by floor digs (26 bedroom → 27 room), size limit (75 room → 155 none); **rooms == full rebuild after every tick**. Stress: rooms == rebuild every 25/50 ticks over 100 000 M3 ticks |
| 4 | Crates: filters, capacity, preferred over zones, never re-hauled, material taken from crates | **PASS** with 1 minor bug | crate preferred over a zone 19 tiles nearer; filtered crate holds only rock; open crate filled to exactly 2000 kg, overflow to zone; stored stacks never moved (new nearer crate, new zone, filter change); table takes exactly 50 kg from a crate; crate deconstructed while a builder walks to its reserved stack: table still built, kg exact. **M3-QA-3**: a stack booked before a filter change is still stored |
| 5 | Deconstruction refunds 100 % (walls, ladders, furniture, crates + contents) | **PARTIAL** | walls, door, crate, bed, table: exact per material; crate with 700 dirt + 300 ore: everything back on supported tiles. **M3-QA-1**: a ladder built from rock refunds dirt (kg right, material wrong) |
| 6 | Building loss: everything drops, no leaked reservations | **PASS** with 1 minor bug | crate lost while a hauler carries to it AND a builder fetches from it: contents + 50 kg refund dropped, bookings released, hauler/builder finish; door lost when its support wall is deconstructed (both refunds); stress digs floors under buildings. **M3-QA-2**: a stale tile-index entry when a 2-tile building being deconstructed is lost (or its whole deconstruct order cancelled) |
| 7 | Save v3 mid-build / mid-deconstruct; v2 and v1 migrate | **PASS** | save/load in fetch-from-crate, carrying, partial delivery and work phases, then built; mid-deconstruct of a 1200 kg crate; real files on a generated world (buildings, orders, filters, rooms identical); v2 save → dropped 0, items identical, colony then builds a crate; v1 (`test_qa_migration`) still passes; orphan crate stacks rescued and reported; 53 random save/loads in the long run |
| 8 | UI: preview == `order_building`; Priority/Cancel/Deconstruct on building orders | **PASS** with 1 minor bug | 3000 random (building, origin) probes in a cluttered world: 0 preview/order mismatches (232 accepted); placement priority, Priority tool on any footprint tile → job follows; Deconstruct ignores unbuilt orders; Cancel removes orders, never buildings, and removes deconstruct orders. **M3-QA-5**: cached preview stays green after the world changes under a motionless pointer |
| 9 | Performance (bench + 100-NPC base with many crates and rooms) | **FAIL** | §5: with 60 crates and 2000 stacks a tick averages **170.7 ms (max 1117 ms)** vs 8.8 ms (max 58 ms) for the same base with zone tiles — **M3-QA-6** |
| 10 | Web smoke with a real browser restart | **PASS** | §6 |

## 4. Long M3 stress (executed)
`godot --headless --path . -s res://tools/qa_stress.gd -- 20000 5 1 8 m3` (128×96, 8 → 24 NPCs, ~3070 random
actions per seed, invariants after every tick, rooms == rebuild every 50 ticks, save/load every 500–3000 ticks,
every 3rd through files). Only the known M3-QA-2 symptom (stale tile index) is tolerated. **RESULT: OK, exit 0.**
| Seed | Save/loads | Buildings placed by NPCs (orders) | Progress kg | avg / max ms per tick | Stuck |
|---|---|---|---|---|---|
| 1 | 14 | 75 (132) | 26 500 | 2.53 / 62.7 | 0 |
| 2 | 9 | 58 (127) | 29 650 | 1.51 / 32.4 | 0 |
| 3 | 10 | 73 (152) | 27 975 | 1.51 / 29.0 | 0 |
| 4 | 9 | 71 (124) | 29 350 | 1.94 / 31.1 | 0 |
| 5 | 11 | 80 (134) | 23 850 | 1.43 / 28.1 | 0 |
Work progressed in every segment between loads (min 100 kg). Times include QA checks. Small 128-wide maps with few
crates at a time, so these runs do not reach the M3-QA-6 regime.

## 5. Performance (executed, headless, quiet machine)
| Probe | avg ms/tick | max ms/tick |
|---|---|---|
| `bench_npcs.gd` 100 NPCs, 441 digs, 600 ticks | 3.13 (jobs 0.34) | 11.96 |
| `qa_bench` A: 100 NPCs + 60 sealed orders | 0.76 | 14.5 |
| `qa_bench` B: 100 NPCs, 2000 stacks, 100 ladders, zones | 3.12 | 34.5 |
| **`qa_bench` C: 100 NPCs, 30 rooms, 60 crates, 30 beds, 2000 stacks** | **170.7 (jobs.update 167.6)** | **1117** |
| `qa_bench` C, same base, zone tiles instead of crates | 8.8 (jobs 7.1) | 58.4 |
Micro costs with 60 crates / 2000 items: `CrateStorage.find_crate()` **23.5 ms per call**, `crate_ids()` 1.34 ms,
`free_capacity()` 0.37 ms. Room updates: 180 digs next to 30 rooms took 149 ms (0.83 ms each). FPS with rendering for
100 NPCs: NOT RUN. Web build: 30–37 FPS with 3 NPCs (headless Edge).

## 6. Web smoke (executed, fixed `tools/web_smoke.mjs`)
`tools/export.ps1 -Preset Web` (exit 0), `node tools/serve_web.js 8060`, fresh profile:
1. New World seed 12345 (world hash 4a8305214f4a, same as M2) → paused → Dig 3×2, Build menu → Storage Crate, Bed
   placed (HUD "orders 6 + 2 bld") → 2x → digs done, crate and bed built from the dug dirt, leftover hauled into the
   crate; Save, Menu (`qa_web_crate_bed_built_saved.png`).
2. Browser restarted (same profile): Play → identical state (tick 1580, buildings 2). Deconstruct tool on the bed →
   removed, its 50 kg refund hauled into the crate (`qa_web_bed_deconstructed_after_restart.png`); Save.
3. Browser restarted again: Play → buildings 1; crate panel "Stored 250 / 2000 kg, Dirt 250 kg" = 300 dug − 100 built
   + 50 refund (`qa_web_crate_250kg_after_2nd_restart.png`). 0 console errors in every run; server stopped.
Rooms were not exercised on Web (surface base only) — covered by §3 #3.

## 7. Bugs
| ID | Severity | Summary | Test (pending) |
|---|---|---|---|
| **M3-QA-6** | **major** | Crate queries scan everything: `free_capacity` → `Inventory.crate_kg` → `crate_items` loops ALL items; `crate_ids()` re-sorts all buildings via `get_building`; `find_crate` / `_book_storage` / `_find_material` / `_has_usable_zone` call these per crate per candidate. 60 crates + 2000 stacks → 170 ms/tick average, 1.1 s spikes (10 Hz needs < 100 ms) | `tools/qa_bench.gd -- 600 only_c` |
| M3-QA-4 | minor (UX, lead a) | "No material" shown as **unreachable**: for an NPC with a recorded (confined) region `_first_goals` returns "no material in reach", `try_assign` treats it as a reach failure (`_mark`) and `_sweep_unreachable` flags the job for everyone. Answer to lead (a): the tint is a JobManager bug, not correct behaviour | `test_lead_a_no_material_confined_npc_not_unreachable` |
| M3-QA-3 | minor | Filter changed while a stack is being carried to a crate: `_drive_haul` stores into the booked crate without re-checking `accepts`; `set_filter` keeps existing bookings | `test_filter_changed_while_carrying` |
| M3-QA-2 | minor | `_unmap_decon_tile` erases `_job_tiles[job]` before `_cancel`, so `_delete_job` misses the other tiles: stale `_by_tile` entries after a whole 2-tile deconstruct order is cancelled or the building is lost mid-deconstruct (no gameplay effect found; index leak) | `test_cancel_whole_building_deconstruct_leaves_no_stale_index`, `test_building_lost_while_being_deconstructed` |
| M3-QA-1 | minor | Ladder deconstruct always refunds dirt (`LADDER_REFUND_MATERIAL`): a rock ladder turns 25 kg rock into dirt | `test_ladder_built_from_rock_refunds_rock` |
| M3-QA-5 | minor (UX) | `ToolController.update_preview` caches per origin: after the world changes under a motionless pointer the preview stays green while `order_building` fails | `test_preview_refreshes_when_world_changes_under_pointer` |

### Reproduction (48×32 grid, rows < 10 air, dirt below, bedrock bottom; feet row 9)
- **M3-QA-6**: `godot --headless --path . -s res://tools/qa_bench.gd -- 600 only_c`.
- **M3-QA-4**: one NPC (5, 9); sealed pocket `apply_edit(Rect2i(30, 20, 4, 3), DIG)` + dig order (30, 19) (forces a
  full search → region recorded); 50 kg rock; crate orders (20, 9) and (22, 9) → after the first crate, "Build crate
  (22, 9) - unreachable" for 2619 of 3000 ticks. Expected: "no material", not tinted.
- **M3-QA-3**: crate (30, 9), zone (40..41, 9), 60 kg dirt (8, 9), NPC (5, 9); when it carries, `set_filter(crate, [rock])`
  → 60 kg dirt ends in the crate.
- **M3-QA-2**: bed (14, 9); deconstruct (14..15, 9); cancel (14..15, 9) → `_by_tile[(15, 9)]` → deleted job.
- **M3-QA-1**: only rock 100 kg; ladder at (12, 9), built, then deconstructed → rock 75, dirt 25.
- **M3-QA-5**: crate placement preview on a valid tile, then a ladder order on that tile; `update_preview(same origin)`
  still ok, `order_building` → overlaps_designation.

### Leads
- (a) answered by M3-QA-4 (bug). A plain two-crate scenario without a recorded region shows no tint
  (`test_lead_a_second_crate_order_not_flagged_unreachable` passes).
- (b) done: harness handles `KIND_BUILDING` / `KIND_DECONSTRUCT`.
- (c) rooms after load: `test_rooms_rebuilt_on_load` + comparator includes rooms in every stress save/load — PASS.

## 8. Not run
FPS with rendering for 100 NPCs; rooms on the Web build; Windows desktop export; mobile/touch.

## 9. Recommendation
**Fix M3-QA-6 first, then close M3.** Gameplay correctness of rooms, buildings, crates, deconstruction, building
loss and save v3 holds under 100 000 ticks of random play with invariants after every tick. But a mid-game base with
~60 crates cannot run at 10 Hz (170 ms/tick, 1 s spikes). The five minor bugs can be fixed in the same round or
carried into M4 as known issues.
