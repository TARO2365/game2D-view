# MILESTONE HANDOFF — M3: Buildings, doors, storage crates, rooms, deconstruction (+ Art V1)

**Date:** 2026-10-21 | **Plan:** `docs/plans/M3_PLAN.md` (approved, D-021) | **Contracts:** `docs/contracts/M3_CONTRACTS.md`
**Agents (D-008):** Lead (contracts, DECONSTRUCT orders, wiring, save v3, tooling), World (buildings, doors, rooms),
Systems (crates, indexed queries), Colony (building orders, deconstruction, crate hauling, fixes), UI (build menu,
placement, rooms overlay, crate panel), Asset (Art V1 spec, prompt pack, procedural art, AI batch 1 import), QA.
**Independent QA report:** `docs/qa/M3_QA_REPORT.md` (+ fixes verified by QA repro tests and Lead runs).

## 1. Acceptance (QA table, after the fix round)
| # | Criterion | Result |
|---|---|---|
| 1 | Buildings built only from hauled material, kg conserved | PASS |
| 2 | Placement rules (door gap D-023, floors, overlaps) | PASS |
| 3 | Rooms follow every edit; incremental = full rebuild | PASS |
| 4 | Crates: filters, capacity, preferred over zones, never re-hauled | PASS (M3-QA-3 fixed) |
| 5 | 100 % deconstruct refund | PASS (M3-QA-1 fixed: ladders refund their real material) |
| 6 | Building loss drops everything, no leaked reservations | PASS (M3-QA-2 fixed) |
| 7 | Save v3 mid-build/mid-deconstruct; v2/v1 migrate | PASS |
| 8 | Placement preview = `order_building`; Priority/Cancel/Deconstruct on building orders | PASS (M3-QA-5 fixed) |
| 9 | Performance with many crates/rooms | PASS after fix: QA base 100 NPCs/60 crates/2000 stacks **207 → 3.4 ms/tick** (max 1174 → 16 ms), Lead-measured same machine |
| 10 | Web smoke with real browser restarts | PASS (QA: crate holds exactly 250 kg after 2 restarts) |

## 2. What was built
- **Buildings:** door (1×3, in a 1-wide gap), storage crate (2000 kg, material filter), bed, table — ordered via the
  Build menu with green/red placement preview, built by NPCs from hauled material.
- **Rooms:** enclosed areas ≤ 128 tiles, typed bedroom / storage / dining / room; overlay with R or "Rooms".
- **Deconstruction tool:** walls, ladders, buildings (crates are emptied first); 100 % refund.
- **Crates:** haulers prefer crates; building inspector shows contents and filter checkboxes.
- **Art (D-020):** Path B code art, then **owner AI batch 1 in game**: 4 roles walk/dig, miner carry/climb, terrain
  (dirt/rock/iron/gold/crystal, seamless), ladder. Missing art falls back sensibly. Prompt pack `docs/art/PROMPTS_V1.md`,
  next list `docs/art/MISSING_V1.md`, import tool `tools/art_import.gd`.
- **Save v3** (buildings, crates, building orders, ladder materials); rooms rebuilt on load; orphan-crate rescue.

## 3. Tests and measurements (executed)
| Run | Result |
|---|---|
| `tools/run_tests.ps1` | **438/438 pass, 0 pending** |
| `tools/run_stress.ps1` | 7/7 pass (M2 + M3 stress), no leak warnings |
| QA long M3 run (5 × 20 000 ticks, 53 save/loads) | 0 violations, rooms = full rebuild every check, 357 buildings built (pre-fix round; fixes re-verified by QA repro tests) |
| `tools/qa_bench.gd` C (60 crates) | 3.4 ms/tick avg, 16 ms max (Lead, final code) |
| Web | QA restarts PASS; Asset Agent AI-art screenshots `docs/handoffs/M3_evidence/ai_v1_*.png` |
| Real GPU / mobile / Windows export of M3 | **NOT RUN** |

## 4. Bugs found and fixed in M3
M3-QA-1 ladder refund material, M3-QA-2 stale deconstruct index, M3-QA-3 filter change mid-haul, M3-QA-4 "no material"
shown as unreachable, M3-QA-5 stale placement preview, **M3-QA-6 crate query performance (major)**, terrain shader
darkening all tiles (Asset), Web smoke tool leaving Edge running, Godot importing `build/`. JobManager crate mirror
removed (D-026). The final fixes were verified by QA's repro tests + Lead runs, not by a separate QA round.

## 5. Open / known
- OQ-22: NPCs idle on a ladder while a nearby dig shows unreachable (seen once in an F9-instant-edit setup) — investigate next QA round.
- OQ-23: seed typed in the dialog not reproducing the world in one smoke run — tests pass; verify manually.
- OQ-20 first-launch Web shader stutter; OQ-17 Thai UI translation; OQ-19 touch untested.
- Art still missing (MISSING_V1.md): dug backwall, sky, bedrock, concrete, idle, other roles' carry/climb, buildings, items, icons.

## 6. Save compatibility
`save_version 3`; v2 and v1 saves migrate (tested). `GEN_VERSION` 1 unchanged.

## 7. Git
All merged to `main`, pushed to https://github.com/TARO2365/game2D-view.

## 8. Next
Owner review → close M3, authorize M4 (needs, food, power, water, room oxygen). Art batch 2 can arrive any time.

## 9. Status
**STATUS: AWAITING OWNER REVIEW / APPROVAL**
