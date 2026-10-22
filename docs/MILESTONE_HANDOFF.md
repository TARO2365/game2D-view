# MILESTONE HANDOFF — M4a: Time, schedules, needs, food, alerts (+ Art D-027)

**Date:** 2026-10-22 | **Plan:** `docs/plans/M4_PLAN.md` (approved, D-028; M4 split into M4a/M4b) | **Contracts:** `docs/contracts/M4A_CONTRACTS.md`
**Agents (D-008):** Lead (contracts, GameTime, AlertService, wiring, save v4, tooling), World (farm plot, kitchen, room
types), Systems (materials/food, farming, kitchens), Colony (needs, schedules, beds, eating/sleeping, farm/cook/feed jobs,
collapse/death), UI (clock, alerts, needs bars, schedule editor, colony overview, food panels, night tint), Asset (art
batch 2, animation fixes, ONI-style terrain, rig pilot, food art), QA. **QA report:** `docs/qa/M4A_QA_REPORT.md`.

## 1. Acceptance (plan §4)
| # | Criterion | Result |
|---|---|---|
| 1 | No food → collapse with alerts → feeding recovers (no instant death) | PASS (death after 6000 ticks collapsed; alert survives load after M4A-QA-1 fix) |
| 2 | Farms + kitchen built from hauled material keep 3 NPCs alive 10 days unattended | PASS — Colony run and QA's own layout (underground base via ladder shaft, 11 save/loads): 0 deaths, 0 collapses |
| 3 | Schedules, owned beds, needs survive save/load mid-action | PASS |
| 4 | Invariants + food kg conservation; 100-NPC bench well under budget | PASS — QA 100 000 random ticks, 52 save/loads, 0 violations; bench with needs on 2.5 ms/tick avg, 17 ms max |
| 5 | Web smoke with real browser restart | PASS — Lead: create world, run to Day 2 03:47 at 3x after a browser restart + load; night tint, sleeping poses, alerts, overview correct |

## 2. What was built
- **Time:** Day/clock (1 day = 10 min at 1x), worlds start Day 1 06:00, smooth dusk/night/dawn tint.
- **Needs:** hunger, stamina, health; collapse → death only after ~1 day untreated; NPCs refuse commands when collapsed.
- **Schedules:** per-NPC 24-hour Work/Sleep/Free editor + apply-to-all.
- **Food:** farm plot (cave mushrooms, needs dirt/rock floor), kitchen (mushroom → meal, keep-in-stock target), eating at
  tables, feeding collapsed colonists, starting 20 kg rations.
- **Beds:** auto-assigned, bedroom bonus, released when a bed is removed.
- **Alerts:** general / important / emergency panel, click to locate; recomputed after load.
- **UI:** needs bars, colony overview (C), farm/kitchen panels, build menu entries.
- **Art (D-027):** ONI-style terrain (continuous textures, organic edges, shading), owner AI batch 2 (sky, cave backwall,
  bedrock, concrete, items, buildings, idle/build/sleep/fall, icons), animation fixes, skeletal rig pilot (miner, rough
  until the owner's parts sheet), procedural food art.
- **Save v4** (farming, kitchens, needs, schedules, recent deaths); v3/v2/v1 migrate.

## 3. Tests (executed)
| Run | Result |
|---|---|
| `tools/run_tests.ps1` | **542/542 pass, 0 pending** |
| `tools/run_stress.ps1` | 8/8 pass, no leak warnings |
| `tools/bench_npcs.gd` | needs off 3.1 ms avg / 10 ms max; needs on 2.5 / 17 ms |
| Web | see §1.5; screenshots `docs/handoffs/M4a_evidence/` |
| Real GPU FPS, mobile/touch, Windows export | **NOT RUN** |

## 4. Bugs found and fixed in M4a
Stale bed ownership after bed removal (found when wiring), M4A-QA-1 death alert lost on load, **M4A-QA-2 exhausted every
evening (balance: stamina now −100 per 20 h)**, M4A-QA-3 Stop while carrying a meal, M4A-QA-4 magenta food, M4A-QA-5 no
night tint, M4A-QA-6 empty alerts after a paused load; web_smoke now uses a free port per run.

**Process notes:** Colony set `needs_enabled = false` in one QA reach test (2-day test without food) — QA reviewed and
accepted. Lead/agents adapted several QA/UI tests to the starting ration and 06:00 start (intent unchanged, commented).

## 5. Known / open
- OQ-20: first Web launch in a fresh browser profile is very slow (1–4 FPS headless) until shaders are cached.
- Rig pilot looks rough until `rig_miner_parts.png` arrives; modular citizens designed, not coded.
- Missing art: icons build_menu/deconstruct/rooms, farm plot, kitchen, food items (procedural fallbacks exist).
- NPC name labels can overlap the toolbar when an NPC stands near the top of the screen (cosmetic).
- OQ-22/OQ-23 from M3 not reproduced by QA.

## 6. Save compatibility
`save_version 4`; v3, v2, v1 load (tested). Older colonies start fed/rested with default schedules.

## 7. Next
Owner review → close M4a, approve **M4b** (power, water, room oxygen; plan §2).

## 8. Status
**STATUS: AWAITING OWNER REVIEW / APPROVAL**
