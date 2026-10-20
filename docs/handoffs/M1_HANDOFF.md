# MILESTONE HANDOFF — M1: Seeded world, chunks, camera, orders, save/load

**Date:** 2026-10-20 | **Roles played (sequential, D-008):** Lead (contracts, persistence), World, UI/UX, QA
**Previous handoffs:** `docs/handoffs/`

## 1. Approved scope and acceptance criteria
Scope = `docs/plans/M1_PLAN.md` as approved (D-015 option A, D-016).

| # | Criterion | Result |
|---|---|---|
| 1 | Same seed ⇒ same world hash; different seeds differ | PASS (unit tests + golden hash) |
| 2 | Medium world generates < 2 s | PASS — 34 ms (Small 19 ms, Large 102 ms) |
| 3 | Dig/build commands validate (bounds, bedrock, air, solid) | PASS (unit tests) |
| 4 | One `tiles_changed` per edit with exact rect; only affected chunks redraw | PASS (unit + integration) |
| 5 | Pan/zoom via mouse, keyboard, touch; camera stays in bounds | PASS mouse/keyboard (tests + Web run); **touch/pinch NOT RUN** on a real device |
| 6 | Save → quit → load reproduces terrain hash, tick, ids, orders | PASS (unit, integration, Web) |
| 7 | Interrupted write keeps previous save; corrupt file → `.bak` | PASS (unit tests) |
| 8 | Max 3 worlds; delete frees slot; one loaded at a time | PASS (unit + app-shell integration) |
| 9 | Web: create, edit, save, restart browser, continue; Web hash = PC hash | PASS (headless Edge, see §4) |
| 10 | M0 tests still pass | PASS (M0 speed-bar checks moved into `test_game_screen.gd`) |

## 2. Files
**Added:** `src/core/{hashing,world_session}.gd`, `src/world/{tile_def,tile_registry,world_grid,world_generator}.gd`,
`src/jobs/designation_map.gd`, `src/persistence/{save_service,world_slots}.gd`,
`src/presentation/{world_view,designation_overlay,camera_controller,tool_controller,placeholder_tiles,game_screen}.gd`,
`src/presentation/ui/{main_menu,toolbar}.gd`, `scenes/{main_menu,game}.tscn`, `data/defs/tile_defs.tres`,
`tools/{bench_world.gd,web_smoke.mjs}`, 9 new test files + `tests/helpers/fs_util.gd`, `docs/handoffs/M1_evidence/*.png`.
**Modified:** `src/presentation/main.gd` + `scenes/main.tscn` (now the app shell: menu ↔ game), `project.godot`
(clear color; integer-division warning off), docs.
**Removed:** `tests/integration/test_main_scene.gd` (M0 scene no longer exists; its checks live in `test_game_screen.gd`).
**Interface decisions:** D-015 (orders only, F9 dev edit), D-016. `WorldGrid.apply_edit()` is the single terrain-mutation
entry point that M2 jobs will call. `DesignationMap` lives in `src/jobs/` for M2's JobManager to consume.

## 3. How to try it
1. Open the project in Godot 4.7.2 and press F5 (or run the Web build: `tools/export.ps1 -Preset Web`, `node tools/serve_web.js`).
2. **New World** → name, optional seed, size → **Create**.
3. Pan: drag with **Select** tool, middle mouse, WASD/arrows. Zoom: wheel or −/+.
4. **Dig** / **Build wall**: drag a rectangle → orange/blue orders appear; terrain does not change (D-015). **Cancel** removes orders.
5. Debug only: **F9** toggles instant edit so Dig/Build change terrain immediately.
6. **Save** / Ctrl+S; **Menu** autosaves and returns. Up to 3 worlds; **Delete** asks for confirmation.

## 4. Tests executed
| Test | Command / method | Outcome |
|---|---|---|
| GUT suite | `tools/run_tests.ps1` | **76/76 pass**, exit 0 |
| Regression test validity | disabled the Ctrl+S fix temporarily | new test failed as expected, restored |
| Benchmark | `godot --headless -s res://tools/bench_world.gd` | gen S/M/L 19/34/102 ms; save 4–6 ms, ~10 KB; load 23/39/109 ms; 24 MB static mem |
| Windows export + run | `tools/export.ps1`, run 300 frames headless | exit 0 |
| Web export | `tools/export.ps1 -Preset Web` | exit 0 |
| Web end-to-end | `node tools/web_smoke.mjs` (headless Edge, SwiftShader) | menu, dialog, create seed 12345, orders, F9 dig, Ctrl+S, **browser restart**, list shows worlds, load ⇒ same hash `200b4b38b7a4` + 12 orders. Screenshots in `docs/handoffs/M1_evidence/` |
| Cross-platform determinism | seed 12345 Medium on Web | hash `84324cbea13c…` = PC golden ✔ (OQ-06 closed) |
| Touch / pinch | — | **NOT RUN** (no touch device; code path only) |
| Mobile export | — | **NOT RUN** (no Android/iOS toolchain) |
| Godot editor GUI | — | **NOT RUN** manually |

> **Correction (2026-10-20, found in M2 QA as QA-11):** the M1 version of `tools/web_smoke.mjs` did not kill the
> headless Edge process tree on Windows, so a later run could attach to the still-running browser. The M1
> "browser restart" evidence therefore proves persistence across a **page reload**, not necessarily a full
> browser restart. The tool was fixed in M2 (`e599cf0`) and a genuine browser-restart persistence check passed in
> M2 QA (`docs/qa/M2_QA_REPORT.md`).

## 5. Bugs found and fixed during QA
1. New World dialog was transparent (menu text showed through) → opaque panel + dimmed backdrop.
2. Ctrl+S also panned the camera down (S = pan key) → camera ignores keys while Ctrl/Alt/Meta held or a text field has focus; regression test added.

**Known limitations:** Web FPS measured only under software rendering (~41–45 FPS, not representative of a real GPU).
UI text is English; Thai text needs a bundled Thai font on Web (OQ-17). "Last played" time may show UTC on Web (OQ-18).
Concrete walls cannot be removed yet (deconstruction = M3).

## 6. Save compatibility
New save format v1 (`save_version 1`, `GEN_VERSION 1`). Any change to world generation must bump `GEN_VERSION`;
older saves are then refused with a clear message (no migration yet, D-016).

## 7. Git
See `git log` — M1 commit on `main`, pushed to https://github.com/TARO2365/game2D-view.

## 8. Deferred / out of scope
NPCs, jobs, hauling, materials, ladders/navigation, rooms, deconstruction, caves, fog of war, stability, real art, Thai localization.

## 9. Next session
Owner review. If M1 is closed and M2 authorized: Lead proposes M2 plan (NPC movement, JobManager consuming
`DesignationMap`, reservations, hauling). D-008: from M2 work is split across separate subagents.

## 10. Status
**STATUS: AWAITING OWNER REVIEW / APPROVAL**
