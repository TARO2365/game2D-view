# MILESTONE HANDOFF â€” M0: Project scaffold

**Date:** 2026-10-19 | **Roles played (sequential, D-008):** Lead Architect, UI/UX, QA

## 1. Approved scope and acceptance criteria
Scope: Git repo, pinned Godot project + renderer, folder structure, docs, core contracts (stubs/no gameplay),
headless test harness, bootable scene with minimal speed UI, Web export smoke test, draft asset conventions.

| Criterion | Result |
|---|---|
| `godot --headless --import` / project opens without errors | PASS |
| Headless test command passes with log evidence | PASS â€” 25/25, 1068 asserts |
| Main scene opens, speed UI shows | PASS (integration tests + Web build in browser) |
| Web export builds and opens in browser | PASS (boots, renders, buttons respond) |
| 7 docs + ownership map exist | PASS (plus OPEN_QUESTIONS, ASSET_CONVENTIONS) |
| Git initial commit | PASS (see Â§7) |
| Handoff report | this file |

## 2. Files added
`project.godot`, `export_presets.cfg`, `.gitignore`, `.gitattributes`, `.gutconfig.json`, `CLAUDE.md`,
`PROJECT_MASTER_SPEC.md` (verbatim copy of v0.1), `src/core/{command_result,stable_id_allocator,simulation_clock,scale_config}.gd`,
`src/presentation/main.gd`, `src/presentation/ui/speed_bar.gd`, `scenes/main.tscn`, `data/config/scale_config.tres`,
`tests/unit/*` (4 files), `tests/integration/test_main_scene.gd`, `tools/{run_tests.ps1,export.ps1,serve_web.js}`,
`docs/*`, `docs/visual/concept/*.png` (4 approved concept sheets), `addons/gut/` (GUT 9.7.1, third-party, MIT).
Interface decisions: D-013 (contracts), D-010 (no autoloads).

## 3. Implemented behavior / reproduction
1. `powershell -File tools/run_tests.ps1` â†’ all tests pass.
2. Open project in Godot 4.7.2 â†’ F5 â†’ dark screen, placeholder notice, top-left Pause/1x/2x/3x + "Tick N | speed".
3. Clicking 3x makes ticks advance 3Ã— faster; Pause freezes the counter.
4. `tools/export.ps1 -Preset Web` then `node tools/serve_web.js` â†’ http://localhost:8060 shows the same.

## 4. Tests executed
| Test | Command | Outcome |
|---|---|---|
| GUT suite | `tools/run_tests.ps1` | 25/25 pass, exit 0 |
| Harness failure detection | temporary failing canary test, then removed | exit 1 (correct) |
| Web export | `tools/export.ps1 -Preset Web` | exit 0, `index.wasm` 37.9 MB, `index.pck` 13 KB (tests/GUT excluded) |
| Web boot | served on localhost, built-in browser | boots, `crossOriginIsolated` true, 3x/Pause clicks change state, pause holds counter |
| Windows export | `tools/export.ps1 -Preset "Windows Desktop"` | exit 0 |
| Windows run | `LastBunker.console.exe --headless --quit-after 300` | exit 0, no errors |
| Web tick timing | â€” | **NOT RUN**: browser pane hidden, `requestAnimationFrame` 0 fps (OQ-11) |
| Mobile export | â€” | **NOT RUN**: no Android/iOS toolchain; not in M0 scope |
| Editor GUI open | â€” | **NOT RUN** manually; headless import + scene instantiation covered |

## 5. Regressions / performance / bugs / limits
No prior code, so no regressions. No performance measurement (nothing to measure yet).
Known limits: tick rate/cadences are placeholders (OQ-15); speed bar touch size placeholder (OQ-13).

## 6. Save compatibility
None yet. `SimulationClock` and `StableIdAllocator` already expose `to_snapshot()/load_snapshot()` for M1.

## 7. Git
Repository initialized in `game2D-view/`; initial commit "M0: project scaffold, core contracts, test harness".
Pushed to https://github.com/TARO2365/game2D-view (branch `main`, initial commit `5a72355`).

## 8. Deferred / out of scope
World, tiles, camera, save files, NPCs, any gameplay; production art; mobile builds; minimum spec (D-012).

## 9. Current state / next session
See `docs/PROJECT_STATE.md`. Before M1, owner should review DECISIONS D-003/D-007 and OPEN_QUESTIONS OQ-01/02/16 (OQ-14 resolved by D-014).

## 10. Status
**STATUS: AWAITING OWNER REVIEW / APPROVAL**
