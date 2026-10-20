# M2 QA REPORT — independent verification of the M2 simulation core

QA Agent, 2026-10-20. Branch `worktree-agent-a09003e8b0a84accf` (base `326285b`).
Scope: M2_PLAN §3 acceptance criteria 1–8. Implementation files were NOT modified.

## 1. What QA added
| File | Purpose |
|---|---|
| `tools/qa_harness.gd` | Drives a real `WorldSession` with seeded random player actions; QA's own invariants (`extra_invariants`) on top of `JobManager.check_invariants` + `Inventory.check_conservation`; save/load comparator; stuck-NPC detector |
| `tools/qa_stress.gd` | Long CLI stress run (default 20 000 ticks × 5 seeds, invariants after every tick, random save/load) |
| `tools/qa_bench.gd` | Performance probes: unreachable orders on a Medium world, item-heavy 100-NPC colony |
| `tests/qa/test_qa_stress.gd` | In-suite stress: 3 seeds × 3000 ticks + acceptance-2 accounting run |
| `tests/qa/test_qa_ladder_shaft.gd` | Acceptance 4: deep cave reachable only via a player-ordered ladder shaft, with save/load mid-work |
| `tests/qa/test_qa_migration.gd` | Acceptance 6: v1 save with 161 dig orders → migrate → NPCs work them |
| `tests/qa/test_qa_edge_cases.gd` | World edges, ladders at bounds, bedrock, stockpile on ladder, full stockpile, walls vs NPCs/items, sealed caves, 100 NPCs on a 40×30 map, deadlock probes |
| `.gutconfig.json` | added `res://tests/qa` to `dirs` (only change outside new files) |

QA extra invariants (checked every tick): open-job buckets and `_prio_count` match the jobs; every open job's
priority equals its order's priority; every order has exactly one job of the same kind and vice versa; no build
site over-delivered; carried stack ≤ carry capacity and one per NPC; ground items in bounds; booking totals per
tile consistent and never above tile capacity; NPCs in bounds; an idle NPC is never on a non-standable tile for
more than 3 ticks.

Save/load comparator (every random save/load): `dropped` all zero; identical per-material kg totals, spawned and
consumed ledgers, item count, NPC count, order count, dig/build job count, zone count, world hash, tick; every
NPC carries the same item id and holds the same job id; every job keeps its worker; build-site kg unchanged;
all invariants hold right after load.

## 2. Test suite result (executed)
`powershell -ExecutionPolicy Bypass -File tools/run_tests.ps1` → exit 0:
**Scripts 32, Tests 220, Passing 217, Pending 3, Failing 0, Asserts 3351** (baseline before QA: 200/200).
The 3 pending tests are the recorded bugs QA-1, QA-3, QA-4; each was confirmed FAILING before `pending()` was added.
Run time grew from ~3 s to ~105 s (QA stress tests); see §6.

## 3. Acceptance criteria
| # | Criterion | Result | Evidence |
|---|---|---|---|
| 1 | No job / item claimed by two NPCs (unit + invariant check in 10-min run) | **PASS** | `qa_stress.gd` 5 seeds × 20 000 ticks (= 33 sim-minutes each) with random actions, invariants after every tick: 0 violations (§4). In-suite seeds 11/12/13 (6/12/24 NPCs). 100 NPCs on a 40×30 map competing for 21 digs: never more busy NPCs than jobs, 0 violations |
| 2 | Dig orders executed by walking NPCs; terrain only via `apply_edit`; one drop per dug tile | **PASS** | `test_dig_and_build_accounting_orders_only`: 6000 ticks of orders-only play; tile-by-tile diff — 0 tiles changed without an order; 257 dug tiles ↔ 12 850 kg spawned (exactly 50 kg each); consumed kg = 84 ladders × 25 |
| 3 | Items move only by carrying; kg conserved across dig/haul/build/save/load | **PASS** | conservation + carry-capacity checks every tick in all runs; per-material totals and ledgers identical across every save/load; ladder-shaft test: final kg = 800 + 7×50 − 24×25 exactly; carried-from-depth observed (24 rows) |
| 4 | Deep dig sites reached via NPC-built ladders from hauled material; unreachable shown | **PASS** (with findings) | `test_deep_cave_reached_only_through_player_ordered_ladder_shaft`: cave orders all flagged unreachable before ladders; after the player orders 24 ladders NPCs build them from stockpiled dirt, dig the cave floor and carry the drops up; finished at tick 5101 with 2 save/loads mid-work. Sealed-cave and v1-buried orders flagged unreachable and never held by an NPC. But see QA-1/QA-3 (jobs stuck *with* a reason shown) and QA-6 (overlay flicker) |
| 5 | Move here / Stop job work, no orphan reservations | **PASS** | random `command_move` / `command_stop` / work toggles in every stress run with invariants each tick (incl. "order has job", bookings belong to haul jobs, carried item belongs to the job); edge test: NPC reaches both world edges and the top/bottom corners by Move here; out-of-bounds targets refused |
| 6 | Save/load mid-work restores without duplication/loss; M1 saves migrate | **PASS** | 5 × 20 000-tick runs and in-suite runs saved/loaded at random moments (in memory and through the real `save` + `load_world` files): comparator found no difference; work continued after each load (progress > 0 per segment in ladder-shaft test). v1 save with 161 orders: dropped 0, 3 NPCs spawned on standable tiles, 1 job per order, all 41 reachable orders dug, 120 buried ones shown unreachable, re-save is v2 and does not spawn a second colony |
| 7 | 100-NPC stress run completes; numbers reported | **PASS** (numbers only, no target set) | §5. Max-tick spikes noted as QA-2 |
| 8 | All M0/M1 tests pass; Web smoke passes | **PARTIAL**: M0/M1 tests PASS; **Web smoke NOT RUN** | full suite green (§2). No Web export / `web_smoke.mjs` run was executed by QA in this session |

## 4. Long stress run (tools/qa_stress.gd, executed)
`godot --headless --path . -s res://tools/qa_stress.gd -- 20000 5 1 8` (128×96 generated world, 8 starting NPCs,
up to 24 NPCs added by actions, action every 1–12 ticks, save/load every 500–3000 ticks, every 3rd via files):

STRESS_RESULTS

## 5. Performance (executed, headless, this PC)
`tools/bench_npcs.gd` (existing, Medium 512×256, 100 NPCs, 441 dig orders, 600 ticks):
avg **3.39 ms/tick** (jobs.update 0.29), max **12.45 ms** (tick 120); path searches 2091 (avg 3.48/tick, max 8 =
budget), 59 expansions / 0.33 ms per search; dug 399/441, 90 busy, 5 confined, invariants OK.

`tools/qa_bench.gd -- 600` (Medium world):
| Scenario | avg ms/tick | max ms/tick | searches | notes |
|---|---|---|---|---|
| A: 3 NPCs, 60 sealed-cave orders (prio 9) + 1 reachable (prio 1) | 0.14 | 23.4 | 7 | reachable order done at tick 515 (control without cave: 305) |
| A: 100 NPCs, same | 4.40 | **128.8** | 201 | reachable order done at tick 456 (control: 500) — no starvation |
| B: 100 NPCs, 2000 loose stacks, 100 ladder orders, 200 zone tiles | 7.26 | **249.2** (388.6 in a 2nd run) | 390 | invariants OK; 73 ladders built in 600 ticks |
In-suite stress (128×96, ≤ 24 NPCs): max ticks 23–171 ms. FPS was NOT measured (headless).

## 6. Bugs and findings
| ID | Severity | Summary | Test |
|---|---|---|---|
| QA-1 | **major** | Builder waits forever on "items in the way" while holding the wall job; nobody else exists to haul the items → permanent deadlock | `test_wall_items_in_way_single_npc_no_deadlock` (pending) |
| QA-2 | minor (perf, no budget set) | Single-tick spikes 129–389 ms with 100 NPCs (unreachable orders / many items) — visible hitches at 10 Hz | `tools/qa_bench.gd` |
| QA-3 | **major** | Two wall builders each stand on the other's wall tile and wait for each other forever ("blocked by NPC") | `test_two_builders_on_each_others_wall_tiles_no_deadlock` (pending) |
| QA-4 | minor | Haul to a stockpile nobody can reach: NPC picks the stack up and drops it again every ~150 ticks forever (20× in 3000 ticks), wasting work and path budget | `test_unreachable_stockpile_no_pickup_livelock` (pending) |
| QA-5 | minor (UI) | An NPC holding a job but waiting (QA-1/QA-3) reports `state == &"idle"` | seen in QA-1/QA-3 failure output |
| QA-6 | minor (UX) | Orders with no work position at all (buried) re-open every `UNREACHABLE_RETRY_TICKS`, so the unreachable overlay is off ~6 % of the time (94 % of samples flagged) | `test_qa_migration.gd` output |
| QA-7 | info | `tests/qa` adds ~100 s to the default suite (TEST_PLAN says stress belongs in an excluded `tests/stress/`); Lead may move `test_qa_stress.gd` there | — |

### Reproduction
**QA-1** (40×30 grid, rows < 10 air, dirt below): stockpile (30..31, 9); one NPC at (5, 9); wall order (12, 9);
50 kg rock at (2, 9); 30 kg dirt at (12, 9). Run 3000 ticks → wall never built; NPC idle at (11, 9) holding
`job:1` "Build wall (12, 9) - items in the way". Same happens with N builders whose walls all have items.
Expected: builder releases the job (or hauls the items away) so the haul job can run.

**QA-3**: same grid; rock 50 kg at (21, 9) and (4, 9); wall orders (12, 9) prio 9 and (13, 9) prio 8; NPC A at
(20, 9); after 3 ticks NPC B at (5, 9). After 3000 ticks: A at (13, 9) holds "Build wall (12, 9) - blocked by
NPC", B at (12, 9) holds "Build wall (13, 9) - blocked by NPC". Expected: one of them steps aside / picks a work
position outside the other wall tile. (A single idle NPC standing in a wall site DOES resolve —
`test_wall_blocked_by_idle_npc_resolves_without_player` passes.)

**QA-4**: same grid; pillar via `apply_edit(Rect2i(30, 6, 1, 4), BUILD_WALL)`; stockpile (30, 5); 50 kg dirt at
(10, 9); NPC at (5, 9). Over 3000 ticks the stack is picked up 20 times and dropped next to where it lay.
Expected: after the first failed delivery the item (or zone) is treated as unreachable until terrain changes.

**QA-2**: `godot --headless --path . -s res://tools/qa_bench.gd -- 600`.

## 7. Not run
- Web smoke run (acceptance 8): NOT RUN.
- FPS with rendering for 100 NPCs: NOT RUN (headless only).
- Touch input: NOT RUN (out of M2 scope).

## 8. Recommendation
RECOMMENDATION
