# PROJECT_STATE.md

**Updated:** 2026-10-20 | **M0:** Closed (owner approved) | **M1:** Authorized; plan `docs/plans/M1_PLAN.md` awaiting owner approval — no M1 code yet

## What exists
- Godot 4.7.2 project (`project.godot`), GL Compatibility renderer, main scene `scenes/main.tscn`.
- Core contracts in `src/core/`: `CommandResult`, `StableIdAllocator`, `SimulationClock`, `ScaleConfig`.
- Minimal UI shell: `SpeedBar` (Pause/1x/2x/3x + tick counter).
- Module folders for all spec §10 boundaries (empty, `.gitkeep`).
- GUT 9.7.1 test harness, 25 tests passing.
- Export presets: Web (single-threaded), Windows Desktop.
- Docs: CLAUDE.md, spec, this file, ROADMAP, DECISIONS, OPEN_QUESTIONS, TEST_PLAN, ASSET_CONVENTIONS, MILESTONE_HANDOFF.

## What does NOT exist yet
No world, tiles, NPCs, jobs, saving, or any gameplay. No production art.

## Repository
https://github.com/TARO2365/game2D-view (branch `main`). Git auth via Git Credential Manager; `gh` CLI not logged in.

## Environment (owner machine)
- Godot: `%LOCALAPPDATA%\Programs\Godot\` (+ export templates in `%APPDATA%\Godot\export_templates\4.7.2.stable`)
- GitHub CLI: `%LOCALAPPDATA%\Programs\gh\bin\gh.exe` (both added to user PATH)
- Node.js available for `tools/serve_web.js`.

## Next session
Read CLAUDE.md. Wait for owner approval of `docs/plans/M1_PLAN.md` (incl. proposals P-1…P-7), then implement M1.
