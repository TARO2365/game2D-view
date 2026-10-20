# MILESTONE HANDOFF — M2: NPCs, movement, jobs, reservations, hauling (+ basic construction)

**Date:** 2026-10-20 | **Plan:** `docs/plans/M2_PLAN.md` (approved, D-017/D-018) | **Contracts:** `docs/contracts/M2_CONTRACTS.md`
**Work split (D-008):** Lead (contracts, priorities/ladder orders, seed, Thai font, save v2 + migration, wiring, tooling),
World Agent (ladder structure layer), Systems Agent (inventory, stockpiles, construction defs),
Colony Agent (NPCs, navigation, jobs; two fix rounds), UI Agent (presentation), QA Agent (independent verification, 2 rounds).
**Independent QA report:** `docs/qa/M2_QA_REPORT.md`.

## 1. Acceptance criteria (plan §3)
| # | Criterion | Result | Evidence |
|---|---|---|---|
| 1 | No job/item claimed twice | PASS | QA stress 5 seeds × 20 000 ticks, invariants every tick, 0 violations |
| 2 | Orders executed by walking NPCs; terrain only via `apply_edit`; one drop per dug tile | PASS | QA accounting run: 0 unordered tile changes, exactly 50 kg per dug tile |
| 3 | Items only move by carrying; kg conserved incl. save/load | PASS | conservation checked every tick; 51 random save/loads, 0 differences |
| 4 | Deep sites reached via NPC-built ladders; unreachable shown | PASS | `tests/qa/test_qa_ladder_shaft.gd` (24 ladders, 2 save/loads mid-work) |
| 5 | Move here / Stop job, no orphan reservations | PASS | random commands in all stress runs + unit tests |
| 6 | Save/load mid-work; M1 saves migrate | PASS | comparator in stress; v1 save with 161 orders migrates, NPCs work them |
| 7 | 100-NPC stress run, numbers reported | PASS (no target set) | §4 |
| 8 | M0/M1 tests pass; Web smoke | PASS | 279/279; Web create → work → save → **real browser restart** → load (QA + Lead runs) |

## 2. What was built
- **NPCs:** 3 starting colonists, unique Thai names (bundled Noto Sans Thai), 3-tile body, walk/step/drop ≤ 4/ladder movement, gravity.
- **Jobs (ONI-style):** dig, build wall, build ladder (materials hauled to the site), haul to stockpile; priorities 1–9;
  per-NPC Dig/Build/Haul toggles; unreachable orders shown red; builders clear items off wall sites and step aside.
- **Items:** inventory with conservation ledger; items fall when unsupported; stockpile zones with capacity bookings.
- **UI:** NPC/item rendering, ladders, tools (Dig, Build wall, Ladder, Stockpile, Clear stockpile, Priority, Cancel),
  NPC inspector (Move here, Stop, work toggles), random seed + re-roll (D-018). Debug: F9 instant edit, F10 spawn NPC.
- **Save v2:** structures, inventory, stockpiles, colony, jobs; v1 (M1) saves migrate and get the starting colony.

## 3. How to try it
`tools/export.ps1 -Preset Web` + `node tools/serve_web.js` (or F5 in Godot) → New World → drag **Stockpile** on flat
ground → **Dig** a pit → **Ladder** down a shaft → watch NPCs dig, haul and build at 3x. Click an NPC (Select tool) to inspect.

## 4. Tests and measurements (all executed this session unless marked)
| Run | Result |
|---|---|
| `tools/run_tests.ps1` | **279/279 pass, 0 pending**, exit 0 (now also fails if any test script cannot load) |
| `tools/run_stress.ps1` | 4/4 pass, no leak warnings |
| QA long stress (`tools/qa_stress.gd`, 5 × 20 000 ticks) | 0 violations, 0 save/load differences, 0 stuck NPCs (QA round 2) |
| `tools/bench_npcs.gd` (Medium, 100 NPCs) | avg 2.76 ms/tick, max 10.5 ms (final code) |
| QA bench (100 NPCs, 60 unreachable orders / 2000 stacks) | max 14.2 / 34.2 ms (was 129 / 389 ms before fixes) |
| Web (headless Edge, SwiftShader) | works; ~37–39 FPS; **first run in a fresh browser profile ran at 1–2 FPS** (shader compilation in software; second world in same profile 39 FPS) — OQ-20 |
| Real-GPU FPS, 100 NPCs rendered, mobile/touch, Windows export of M2 | **NOT RUN** |

## 5. Bugs found and fixed during M2
QA-1 builder deadlock on items, QA-2 tick spikes, QA-3 mutual wall blocking, QA-4 haul pick-up/drop livelock,
QA-5 "idle" while holding a job, QA-6 unreachable flicker, QA-8 haul booking unreachable stockpile, QA-9 items on
ladders floating, floating items after digging (UI Agent), transparent inspector, QA-11 Web smoke tool reused stale
browsers, test runner ignoring unloadable test scripts. Fixes for QA-8/QA-9 were verified by QA's own repro tests and
Lead test runs, not by a separate QA round.

**Process notes:** the Colony Agent corrected one fixture tile in a QA-owned test (`test_qa_fixes.gd`, QA-8): the
original "reachable" zone tile was behind a 4-tall pillar and could never be reached; the assertion is unchanged.
The M1 handoff's "browser restart" evidence may have been a page reload (QA-11) — correction note added there.

## 6. Known limitations
- NPCs who dig themselves into a pit without ladders stay there until the player orders ladders (ONI-like, by design).
- Unreachable-stockpile memory is not saved: one wasted trip per load. Long paths > 4000 expansions count as unreachable.
- QA-12: with the bench's pit, more NPCs end up confined (real confinement, not a defect).
- UI English except NPC names (OQ-17); touch untested (OQ-19); layout checked at 1280×720 only.

## 7. Save compatibility
`save_version 2`. M1 (v1) saves load via migration (tested). `GEN_VERSION` unchanged (1).

## 8. Git
All work merged to `main` and pushed to https://github.com/TARO2365/game2D-view (see `git log`).

## 9. Out of scope / deferred
Needs, schedules, skills, rooms, storage buildings, doors, deconstruction, combat, real art, Thai UI translation.

## 10. Status
**STATUS: AWAITING OWNER REVIEW / APPROVAL**
