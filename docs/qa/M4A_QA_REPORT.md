# M4a QA REPORT — time, schedules, needs, food, alerts

QA Agent, 2026-10-22, on main `9929614` merged into the QA branch. Implementation files were not modified.
Every bug below has a test that was confirmed FAILING before `pending()` was added.

## 1. What QA added / changed
| File | Purpose |
|---|---|
| `tools/qa_harness.gd` | `m4a_invariants` (needs in 0..100; bed owners and table users unique; a food stack held/reserved by one NPC only and never also by a job; collapsed / eating / sleeping NPCs hold no job; every food reservation mirrored by its NPC); save/load comparator extended with per-NPC needs, condition, schedule, bed, activity/phase, food item, table, collapsed_since, deaths, farming and kitchen snapshots; `enable_m4a()` random actions (food spawns, farm plot / kitchen orders, schedules incl. all-work / all-sleep / random, bed assignment, hunger / stamina / health spikes, kitchen targets) |
| `tools/qa_m3_env.gd` | v4 load order (farming, kitchens before colony) |
| `tools/qa_stress.gd` | 5th arg `m4a`; strict again (M3-QA-2 is fixed, nothing tolerated) |
| `tests/stress/test_qa_m4a_survival.gd` | Acceptance 2–4 with an independent layout: 3 farm plots on the surface, an underground kitchen / table / 3 beds / crate reached only by a ladder shaft, everything ordered and built by NPCs from hauled material, 10 days, save/load mid-eat / mid-sleep / mid-cook + every 7000 ticks |
| `tests/qa/test_qa_m4a_needs.gd` | Starvation, collapse, rescue, death; pre-emption of every job phase; GameTime boundaries; schedules; alerts |
| `tests/qa/test_qa_m4a_edges.gd` | Furniture removed mid-use, farm losing soil, kitchen lost mid-cook, food in filtered crates, food out of reach of a confined NPC, a collapsed NPC falling |
| `tests/qa/test_qa_m4a_ui.gd` | Food art (magenta), lying poses, alerts right after a paused load |
| `tests/stress/test_qa_m3_stress.gd` | Made strict (M3-QA-2 fixed) |

## 2. Suites (executed)
- `tools/run_tests.ps1` → exit 0: **Scripts 66, Tests 540, Passing 535, Pending 5, Failing 0** (main before QA: 516/516).
  Pending = M4A-QA-1, -2, -3, -4, -6.
- `tools/run_stress.ps1` → exit 0: **8/8** (M2 stress ×4, M3 stress ×3, M4a 10-day survival).
- All earlier M3 repro tests (M3-QA-1/2/3/4/5) now pass unchanged → **M3 fixes verified**; M3-QA-6 verified by bench (§5).
- Long run `qa_stress.gd -- 20000 5 1 8 m4a` → **RESULT OK** (§4).

## 3. Acceptance (M4_PLAN §4)
| # | Criterion | Result | Evidence |
|---|---|---|---|
| 1 | No farms: food runs out, NPCs collapse with alerts, feeding recovers them; no instant death | **PASS** | `test_collapse_alerts_survive_load_then_rescue_by_feeding`: collapse → `npc/collapsed` EMERGENCY + `colony/no_food` IMPORTANT; save/load while collapsed (identical, alerts re-raised); Move here refused; save/load mid-feed (meal in the feeder's hands); patient fed, gets up, alert cleared. `test_death_drops_items_releases_everything_and_alert_stays`: collapse while hauling drops the stack and releases the job; death after 6000 ticks; kg intact; nothing held by the dead NPC; "died" alert stays — **but not across save/load (M4A-QA-1)** |
| 2 | Farms + kitchen built from hauled materials keep 3 NPCs alive 10 days unattended | **PASS** | `test_ten_days_underground_base_with_save_load_mid_activity`: all 9 buildings built by NPCs by tick 1123; 10 days; 0 deaths, 0 collapses; 41.5 kg meals and 50 kg mushrooms eaten, 112 kg mushrooms in stock at the end; 11 save/loads. Note: lowest hunger 5.8 (critical) although food was plenty — NPCs go to bed hungry, consequence of M4A-QA-2 |
| 3 | Schedules followed (sleep in owned beds at night); needs/schedules survive save/load mid-action | **PASS** with bugs | save/load mid-eat, mid-sleep, mid-cook, mid-feed, while collapsed, while sleeping on the floor, while walking to a bed: comparator identical (needs, schedule, bed, activity, food item, table, collapsed_since). Default schedule → in bed after 22:00, wakes after 06:00 rested; all-work NPC still sleeps when exhausted; all-sleep sleeps most; schedule changed mid-sleep → sleeps until rested, then follows it; bed ownership unique every tick in all runs. **M4A-QA-2**: on the default schedule a rested NPC is exhausted at 19:36 every day |
| 4 | M0–M3 invariants hold incl. food kg; 100-NPC bench well under 100 ms/tick | **PASS** | conservation (incl. eating/cooking/feeding) and all invariants every tick in 100 000 ticks of random M4a play; no double food reservation. Bench with needs on: **2.57 ms avg, 17.2 ms max** (§5). One invariant bug found by the random run: **M4A-QA-3** |
| 5 | Web smoke with real browser restart | **PASS** with bugs | §6 (clock, night, sleeping poses, needs bars, colony overview, inspector + schedule button survive a restart; **M4A-QA-6** alerts empty after a paused load; **M4A-QA-4** magenta food; **M4A-QA-5** no night darkening) |

## 4. Long M4a stress (executed)
`qa_stress.gd -- 20000 5 1 8 m4a` (128×96, 8 → 24 NPCs, ~3070 random actions incl. M3 + M4a actions per seed,
invariants after every tick, rooms == rebuild every 50 ticks, 52 save/loads, every 3rd through files) — strict
except that the "stop" action skips NPCs holding a meal (known M4A-QA-3). **RESULT: OK.**
| Seed | Loads | Deaths | Meals / rations / mushrooms eaten (kg) | avg / max ms | Stuck |
|---|---|---|---|---|---|
| 1 | 10 | 0 | 93.1 / 24.3 / 46.0 | 1.09 / 33.4 | 0 |
| 2 | 11 | 0 | 114.0 / 32.0 / 2.4 | 1.22 / 38.1 | 0 |
| 3 | 12 | **2** | 76.8 / 41.7 / 16.4 | 1.08 / 30.0 | 0 |
| 4 | 9 | 0 | 92.9 / 37.3 / 13.8 | 0.85 / 20.8 | 0 |
| 5 | 10 | 0 | 71.4 / 21.4 / 13.5 | 0.69 / 18.3 | 0 |
Deaths (from forced health spikes) happened with every invariant checked each tick — death path verified under load.

## 5. Performance (executed, headless, quiet machine)
| Probe | avg ms/tick | max ms/tick |
|---|---|---|
| `bench_npcs.gd` needs off (100 NPCs, 441 digs) | 3.15 | 11.3 |
| `bench_npcs.gd` **needs on** (100 NPCs, 40 beds, 10 tables, 8 farms, 2 kitchens, 60 food stacks, 21:30 → 23:54) | **2.57** | **17.2** (tick 4000 = 22:00 bedtime) |
| `qa_bench` C (M3 base, 100 NPCs, 60 crates, 2000 stacks; needs on via `create_new`) | 6.19 | 14.8 (was 170.7 / 1117 — **M3-QA-6 fixed**) |
| same base with zone tiles | 5.45 | 14.6 |
Micro: `find_crate()` 0.077 ms (was 23.5), `crate_ids()` 0.001 ms. FPS with rendering for 100 NPCs: NOT RUN.

## 6. Web smoke (executed, `tools/web_smoke.mjs`)
Export (exit 0) → `serve_web.js` → fresh profile: New World → game at **Day 1 06:00** (sun icon), ONI-style terrain
and backdrop render, alerts panel "No alerts", colony overview (food in stock: ration 20 kg, 3 colonists with bars).
3x until night → **Day 1 23:18** (moon), all 3 NPCs **sleeping in the lying/curled pose**, alerts (badge 4):
"3 colonist(s) without a bed", "… is hungry" ×2; Save; Menu. **Browser restarted**, same profile, Play → tick 4328,
Day 1 23:18, identical need bars, colony overview "sleeping" ×3, inspector shows Hunger / Stamina / Health, bed
"Auto", Farm/Cook toggles, Schedule button — **but the alerts panel shows "No alerts"** until the clock runs; after a
few ticks the same 4 alerts are back (M4A-QA-6). 0 console errors; server stopped.
Art regression: **no magenta in the terrain, NPCs or UI**, but the starting **ration stack is drawn magenta**
(#FF00FF pixels sampled at the stack; M4A-QA-4). Sky brightness sampled at 06:00 / evening / 23:18: 95.6 / 93.6 /
96.0 → **no night darkening** (M4A-QA-5). Farm plot / kitchen art: code review only (own `draw_art` branches);
visually NOT RUN on Web. Menu still says "M3 build — placeholder art" (cosmetic).
Evidence: `docs/handoffs/M4a_evidence/qa_web_*.png`.

### web_smoke.mjs leftover Edge on port 9333 — investigation (executed)
| Scenario | Browsers on 9333 afterwards |
|---|---|
| normal run | 0 |
| profile path with a space | 0 |
| profile path with `[1]` (PowerShell `-like` wildcard chars) | 0 |
| Node killed mid-run (`Stop-Process -Force` after 10 s, simulating a tool timeout / Ctrl-C) | 0 (Edge exits with its parent); the next run works |
**Not reproduced.** Remaining explanations: (1) two runs at the same time (another agent/worktree; all use port 9333):
the second exits with "Port 9333 is already in use" — that browser belongs to the first run, it is not a leftover;
(2) a run started within ~5 s of a previous one while its Edge is still exiting (the cleanup waits up to 5 s).
Suggestion (Lead): a per-run port (`LB_PORT` or a free port) would remove both.

## 7. Bugs
| ID | Severity | Summary | Test (pending) |
|---|---|---|---|
| **M4A-QA-2** | **major** (balance) | Stamina −100 / 16 h awake and "exhausted" < 15: a rested NPC on the default 06–22 schedule is exhausted at **19:36 every day** → exhaustion alert daily, sleeps 2.5 h early (often hungry, so it wakes at critical hunger) | `test_default_schedule_reaches_bedtime_without_exhaustion` |
| M4A-QA-3 | minor | "Stop" (and anything using `JobManager.release_npc`, e.g. step-aside) on an NPC carrying its meal puts the meal down but leaves `_food_item` pointing at an unreserved ground stack; the NPC "eats" with empty hands (invariant "meal item … not reserved for it"). Found by the random stress | `test_stop_while_carrying_meal_leaves_no_dangling_food` |
| M4A-QA-1 | minor | The "has died" alert disappears after save/load (alerts not saved; no producer re-raises it; the deaths counter survives) | `test_death_alert_survives_load` |
| M4A-QA-6 | minor (UX) | After loading a game saved while paused the alerts panel is empty until the first tick (emergency "collapsed" not shown) | `test_alerts_present_right_after_loading_a_paused_game` |
| M4A-QA-4 | minor (art) | Food stacks (ration, meal, mushroom) draw magenta on the ground (`ItemView` colours only from tile defs) and when carried (`NpcView.material_art_color`) | `test_food_items_have_art_not_magenta` |
| M4A-QA-5 | minor (plan item 1) | Surface does not darken at night (only the clock icon changes) | Web screenshots (brightness); not unit-testable headless |

### Reproduction (48×32 grid, rows < 10 air, dirt below, bedrock bottom; feet row 9)
- **M4A-QA-2**: one NPC (6, 9), 20 kg ration, a bed; run 3990 ticks from tick 0 (06:00) → exhausted alert at Day 1 19:36,
  asleep at 21:58.
- **M4A-QA-3**: NPC (6, 9), 4 kg meal (10, 9), hunger 20; when it carries the meal → `command_stop` → `check_invariants`
  reports "npc:1 meal item item:2 not reserved for it"; hunger is not restored.
- **M4A-QA-1**: NPC hunger 0, health 0.5 → collapses → dies at +6000 ticks → save/load → `npc:1/died` gone.
- **M4A-QA-6**: as above until collapsed; save/load; no tick → `alerts()` empty (3 alerts before).
- **M4A-QA-4**: spawn any food stack; Web: the starting ration at the first colonist is a magenta chunk.

## 8. Review: `needs_enabled = false` in `test_wall_line_many_builders`
**Acceptable.** The test (M2/M3 QA) is about wall reach rules over 12 000 ticks with no food; with needs on, the
builders starve and collapse, which tests something else. Needs/food interplay with building and every job phase is
covered by `test_qa_m4a_needs.gd` (pre-emption while hauling, delivering, building, cooking) and by the M4a stress.
Suggestion only: give it rations instead, so it keeps needs on.

## 9. Not run
FPS with rendering for 100 NPCs; farm plot / kitchen art on Web; touch/mobile; Windows desktop export.

## 10. Recommendation
The survival loop works and is robust: 10 unattended days in an independent underground layout, 100 000 ticks of random
M4a play with collapses and deaths, invariants and kg conservation every tick, and save/load in every activity. All M3
bugs are verified fixed, and performance is good (2.6 ms/tick with 100 NPCs and needs on). **Recommendation: fix
M4A-QA-2 (stamina vs default schedule) and M4A-QA-3 (Stop while carrying a meal) first, then close M4a.** The other
four are small UX/art issues that can go into the same round or M4b.
