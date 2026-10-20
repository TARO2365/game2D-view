# M2 QA REPORT — independent verification of the M2 simulation core

QA Agent. Round 1: 2026-10-20 on `326285b` (commit 351c5dc). **Final round: 2026-10-20 on main `25e5ad0`**
(Colony fix round for QA-1/3/4/5/6, item gravity, tick spikes) merged into the QA branch.
Scope: M2_PLAN §3 acceptance criteria 1–8. QA did not modify implementation files.

## 1. What QA added
| File | Purpose |
|---|---|
| `tools/qa_harness.gd` | Drives a real `WorldSession` with seeded random player actions; QA's own invariants (`extra_invariants`) on top of `JobManager.check_invariants` + `Inventory.check_conservation`; save/load comparator; stuck-NPC detector |
| `tools/qa_stress.gd` | Long CLI stress run (20 000 ticks × 5 seeds, invariants after every tick, random save/load) |
| `tools/qa_bench.gd` | Perf probes: unreachable orders on a Medium world; 100 NPCs + 2000 stacks + 100 ladder orders |
| `tools/qa_web_smoke.ps1` | Wrapper for `web_smoke.mjs` that really restarts the headless browser (see QA-11) |
| `tests/stress/test_qa_stress.gd` | 3 seeds × 3000 ticks random play with save/load + acceptance-2 accounting run (moved here by the Lead, run with `tools/run_stress.ps1`) |
| `tests/qa/test_qa_ladder_shaft.gd` | Acceptance 4: deep cave reachable only via a player-ordered ladder shaft, save/load mid-work |
| `tests/qa/test_qa_migration.gd` | Acceptance 6: v1 save with 161 dig orders → migrate → NPCs work them |
| `tests/qa/test_qa_edge_cases.gd` | World edges, ladders at bounds, bedrock, stockpile on ladder, full stockpile, walls vs NPCs/items, sealed caves, 100 NPCs on 40×30, QA-1/3/4 repros |
| `tests/qa/test_qa_fixes.gd` | Final round: re-verification of QA-1..6 + item gravity, attempts to break the fixes, QA-8/QA-9 repros |
| `tests/qa/test_qa_leaks.gd` | Session teardown: weakrefs after play, after save/load, after GameScreen → quit to menu |

QA extra invariants (every tick): open-job buckets/`_prio_count` match the jobs; open job priority = order
priority; every order has exactly one job of its kind and vice versa; no build site over-delivered; carried stack ≤
carry capacity and one per NPC; ground items in bounds; booking totals per tile consistent and ≤ tile capacity; NPCs
in bounds; an idle NPC never stands on a non-standable tile > 3 ticks.
Save/load comparator: `dropped` all zero; identical per-material kg, spawned/consumed ledgers, item/NPC/order/
dig-build-job/zone counts, world hash, tick; every NPC keeps its carried item id and job id; every job keeps its
worker; build-site kg unchanged; all invariants hold right after load.

## 2. Test results (executed, final round)
- `powershell -ExecutionPolicy Bypass -File tools/run_tests.ps1` → exit 0: **Scripts 35, Tests 277, Passing 275,
  Pending 2, Failing 0, Asserts 3691** (pending = open bugs QA-8, QA-9; both confirmed FAILING before `pending()`).
  No "ObjectDB instances were leaked" warning.
- `powershell -ExecutionPolicy Bypass -File tools/run_stress.ps1` → exit 0: **4/4 passed**, no leak warning
  (it printed "526 ObjectDB instances were leaked" before; cause found in QA's own test, see QA-10).
- QA tests: 38 in `tests/qa` + 4 in `tests/stress`.

## 3. Acceptance criteria (final)
| # | Criterion | Result | Evidence |
|---|---|---|---|
| 1 | No job / item claimed by two NPCs | **PASS** | `qa_stress.gd` 5 seeds × 20 000 ticks (33 sim-min each, up to 24 NPCs, ~3100 random actions per seed) with invariants after EVERY tick: 0 violations (§4). In-suite stress seeds 11/12/13. 100 NPCs on a 40×30 map: never more busy NPCs than jobs |
| 2 | Digs done by walking NPCs; terrain only via `apply_edit`; one drop per dug tile | **PASS** | `test_dig_and_build_accounting_orders_only`: tile-by-tile diff after 6000 ticks of orders-only play — 0 unordered terrain changes; 260 dug tiles ↔ 13 000 kg spawned (50 kg each); consumed = 77 ladders × 25 kg |
| 3 | Items move only by carrying; kg conserved across dig/haul/build/save/load | **PASS** | conservation + carry checks every tick in all runs; totals/ledgers identical across 51 save/loads in the long run; ladder-shaft final kg exact; gravity keeps item ids/kg (`relocate_ground`) |
| 4 | Deep sites reached via NPC-built ladders from hauled material; unreachable shown | **PASS** | ladder-shaft test: cave orders flagged unreachable, then 24 ladders built from stockpiled dirt, cave dug, drops carried up 24 rows, with 2 save/loads mid-work. Buried orders now stay flagged 100 % of the time (QA-6 fixed). Leftover walls the player sealed off are shown unreachable and held by nobody |
| 5 | Move here / Stop job work; no orphan reservations | **PASS** | random Move here / Stop / work toggles in every stress run, invariants each tick; NPCs reach both world edges and top/bottom corners |
| 6 | Save/load mid-work without duplication/loss; M1 saves migrate | **PASS** | comparator clean on every random save/load (memory + real files); also mid-fall and mid-"clear" phase (`test_clear_phase_survives_save_load`, `test_save_load_during_npc_fall`); progress > 0 after every load (§4). v1 save with 161 orders: dropped 0, 3 NPCs, 1 job per order, 41 reachable dug, 120 buried flagged, re-save v2 |
| 7 | 100-NPC stress run completes; numbers reported | **PASS** (numbers only, no target set) | §5 |
| 8 | All M0/M1 tests pass; Web smoke passes | **PASS** | full suite green (§2). Web smoke §6: Web export + headless Edge, world created (seed 12345), stockpile/dig/ladder placed with the toolbar, NPCs dug and built the ladder, saved, browser restarted twice with the same profile — identical state (tick 1679, world hash 91142a3ce38c, 3 NPCs, 6 jobs), stacks then hauled into a new zone and still there after the 2nd restart; 0 console errors |

## 4. Long stress run (executed, final code)
`godot --headless --path . -s res://tools/qa_stress.gd -- 20000 5 1 8` (128×96 world, 8 → 24 NPCs, action every
1–12 ticks, save/load every 500–3000 ticks, every 3rd through real files). **RESULT: OK, exit 0.**
| Seed | Actions | Save/loads | Jobs at end | Items | Progress (kg dug+built) | avg ms/tick | max ms/tick | Stuck NPCs |
|---|---|---|---|---|---|---|---|---|
| 1 | 3076 | 12 | 387 | 412 | 14 800 | 1.54 | 67.4 | 0 |
| 2 | 3088 | 9 | 533 | 437 | 18 150 | 1.39 | 32.3 | 0 |
| 3 | 3046 | 11 | 491 | 566 | 25 525 | 0.95 | 21.0 | 0 |
| 4 | 3097 | 10 | 465 | 518 | 20 500 | 1.17 | 27.0 | 0 |
| 5 | 3151 | 9 | 347 | 552 | 21 950 | 0.73 | 24.6 | 0 |
Progress in every segment between two loads was > 0 (min 125 kg, max 6425 kg). 0 invariant violations, 0 comparator
differences. (ms include QA invariant checks after every tick.)

## 5. Performance (executed, headless, this PC)
| Probe | Round 1 (326285b) | Final (25e5ad0) |
|---|---|---|
| `bench_npcs.gd` 100 NPCs, 441 digs, 600 ticks: avg / max ms | 3.39 / 12.45 | **2.83 / 12.20** |
| … searches, dug, busy / confined | 2091, 399/441, 90 / 5 | 1143, 374/441, 68 / 37 |
| `qa_bench` A, 3 NPCs, 60 sealed orders: avg / max ms | 0.14 / 23.4 | **0.05 / 9.4** |
| `qa_bench` A, 100 NPCs, 60 sealed orders: avg / max ms | 4.40 / 128.8 | **0.72 / 14.2** |
| `qa_bench` B, 100 NPCs, 2000 stacks, 100 ladders: avg / max ms | 7.26 / 249.2 (388.6) | **3.03 / 34.2** |
Reachable low-priority order with 60 sealed orders present: done at tick 115 (3 NPCs) / 490 (100 NPCs), controls
305 / 500 — no starvation. FPS: Web build 37–41 FPS in headless Edge (swiftshader) with 3 NPCs; 100-NPC FPS with
rendering NOT RUN. Note QA-12 on the bench throughput change.

## 6. Web smoke (executed)
`tools/export.ps1 -Preset Web` (exit 0) → `node tools/serve_web.js 8060` → `tools/qa_web_smoke.ps1` (fresh profile):
1. New World, seed 12345 (Medium), Create → game screen, 3 NPCs with Thai names.
2. Paused; Stockpile (4 tiles), Dig (3×2), Ladder (2) via the toolbar → orders 8, jobs 8.
3. 2x speed: by tick 667 all digs done and the ladder built (`qa_web_orders_done_tick667.png`). The dig cut the only
   walkable step to the stockpile ledge, so 6 haul jobs waited (correctly, no pick-up loop). Saved ("Saved" toast), Menu.
4. Browser killed and restarted with the same profile: Play → identical state (`qa_web_loaded_after_browser_restart.png`).
5. Added a reachable stockpile; stacks hauled in; saved; 2nd restart + 40 s: jobs 0, all stacks stored
   (`qa_web_hauled_to_stockpile_after_2nd_restart.png`). Console: 0 errors in every run. Server and browsers stopped.
Screenshots: `docs/handoffs/M2_evidence/qa_web_*.png`.

## 7. Leak check (QA-10) — no game leak
`tests/qa/test_qa_leaks.gd` (all pass): after real play, after save + `load_world`, and after
`Main.start_game` → `GameScreen.quit_to_menu` (autosave + screen freed), weakrefs to the session, grid, designations,
inventory, stockpiles, nav, jobs, colony, clock, ids, an NPC, a job, an item and the GameScreen are all gone;
`Performance.OBJECT_COUNT` returns exactly to baseline (delta 0) after two play/forget cycles.
The 526 leaked objects of `run_stress.ps1` came from QA's own `test_dig_and_build_accounting_orders_only`: a lambda
capturing the QA harness `h` was connected to `h.s.designations.designations_changed` (h → session → designations →
signal → lambda → h, a RefCounted cycle). Running only that test reproduced exactly 526; disconnecting the lambda at the
end removed the warning. Test-harness only; no session cycle in game code (JobManager → Colony is a WeakRef).

## 8. Bugs and findings
| ID | Severity | Summary | Status | Evidence |
|---|---|---|---|---|
| QA-1 | major | Builder waited forever on "items in the way" | **FIXED — verified** | repro passes; also 450 kg (3 trips) + 3 walls, single NPC, no stockpile; save/load in the new clear phase; tunnel case |
| QA-2 | minor (perf) | Single-tick spikes 129–389 ms with 100 NPCs | **FIXED — verified** | §5: max 14.2 / 34.2 ms |
| QA-3 | major | Two wall builders blocked each other forever | **FIXED — verified** | repro passes; 8 NPCs on an 18-wall block (some starting inside it): nobody walled in; NPC walked onto a wall site steps aside after arriving |
| QA-4 | minor | Pick-up/drop loop for an unreachable stockpile | **FIXED — verified** | 1 pick-up / 3000 ticks; 10-tile unreachable zone: 1 / 6000. Memory is not saved: 1 extra trip per load (5 in 5 loads) — accepted |
| QA-5 | minor (UI) | Job holder shown `idle` while waiting | **FIXED — verified** | `test_qa5_waiting_state_reported` (`waiting`) |
| QA-6 | minor (UX) | Buried-order overlay flickered | **FIXED — verified** | `test_qa6_buried_order_flag_stable`: flagged in 100 % of samples |
| QA-7 | info | QA stress slowed the default suite | **DONE** (Lead moved it to `tests/stress`) | default suite 14 s |
| Gravity | — | Items fall when terrain under them goes | **VERIFIED** | reserved stack falls mid-haul (same id) and is still delivered; stacks fall through ladders into a zone at the shaft bottom; save/load mid-fall clean (no floating stacks after it); not checked inside the random stress runs |
| QA-8 | **major** | A haul job books the NEAREST zone tile with space regardless of who can reach it; the NPC that failed there skips the job, but the job keeps that booking, so a reachable (farther) zone is never used | **OPEN** (pending test) | `test_unreachable_nearest_zone_does_not_block_reachable_zone`: after 4000 ticks the stack lies at (24, 9), "Haul dirt 50 kg" open, reachable tile (37, 9) empty. Seen on Web: 3 stacks waited until a later reload |
| QA-9 | minor | A stack put down on a ladder mid-shaft (Stop job / Move here / no-drop-tile cases drop at `npc.tile`) floats in mid-air until a later terrain change in that column | **OPEN** (pending test) | `test_drop_from_ladder_mid_shaft_does_not_float`: stack at (20, 17) with no floor below |
| QA-10 | info | "526 ObjectDB instances leaked" in run_stress | **FIXED** (QA test-harness cycle) | §7 |
| QA-11 | minor (tooling) | `tools/web_smoke.mjs`: `proc.kill()` leaves headless Edge running on Windows; the next run silently attaches to the old browser on port 9333 (old profile/page), so "fresh profile" and "browser restart" checks are invalid. Four stale browsers from earlier runs were found and stopped | **OPEN** (workaround `tools/qa_web_smoke.ps1`) | earlier runs showed worlds in a "fresh" profile |
| QA-12 | info | `bench_npcs`: after the fix round fewer tiles are dug in 600 ticks (374 vs 399) and 37 NPCs count as confined (was 5), likely the shared region cache (`_adopt_cached_region`); not proven to be a bug | observe | §5 |

### Reproduction (open bugs)
**QA-8** (40×30 grid, rows < 10 air, dirt below, bedrock bottom): `apply_edit(Rect2i(30, 6, 1, 4), BUILD_WALL)`
(pillar); stockpile (30, 5) (unreachable) and (37, 9) (reachable); 50 kg dirt at (25, 9); one NPC at (5, 9).
Run 4000 ticks → stack still loose. Expected: the haul is re-booked to a zone tile the NPC can reach.
**QA-9**: shaft x=20 rows 10..21 with ladders, side room (21..26, 19..21), stockpile (2..3, 9), 60 kg dirt at
(24, 21), NPC at (10, 9). When the NPC climbs the shaft carrying the stack (y 12..17), `command_stop` → the stack is
on (20, y) with air below. Expected: it lands on the shaft floor (like terrain-triggered gravity).

## 9. Not run
- FPS with rendering for 100 NPCs (Web or desktop): NOT RUN.
- Real mobile/touch: NOT RUN (out of M2 scope).
- Windows desktop export in this round: NOT RUN.

## 10. Recommendation
All 8 acceptance criteria PASS on 25e5ad0, QA-1..QA-6 are fixed and verified, and there is no session leak.
**Recommendation: fix QA-8 first, then close M2.** QA-8 is small and contained in hauling, but it can leave items
loose for a long time even though a reachable stockpile exists, and players will hit it whenever a zone tile becomes
unreachable. QA-9 (minor) and QA-11 (tooling) can be carried into M3 as known issues if the owner prefers.
