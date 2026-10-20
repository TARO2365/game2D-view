# PROJECT_STATE.md

**Updated:** 2026-10-20 | **M0, M1:** Closed | **M2:** In review (handoff `docs/MILESTONE_HANDOFF.md`) | **Next authorized:** none

## What exists (playable)
- Main menu: up to 3 stored worlds, one played at a time; New World with name, random seed (re-roll), size.
- Seeded finite world, chunk-streamed placeholder art, ladders.
- 3 NPCs with Thai names who dig, haul to stockpiles and build walls/ladders from hauled material (ONI-style orders,
  priorities 1–9, per-NPC work toggles, Move here / Stop, unreachable orders shown).
- Items with gravity and mass conservation; save v2 with M1 migration; manual save + autosave.
- 279 tests (`tools/run_tests.ps1`), stress (`tools/run_stress.ps1`), benches (`tools/bench_*.gd`, `tools/qa_bench.gd`),
  Web smoke (`tools/web_smoke.mjs`, now kills its browser and refuses a busy debug port).

## Not yet
Needs/food/sleep, schedules, skills, rooms, storage buildings, doors, deconstruction, combat, real art, Thai UI.

## Repository
https://github.com/TARO2365/game2D-view (branch `main`). Git auth via Git Credential Manager; `gh` CLI not logged in.
Agent worktrees live in `.claude/worktrees/` (git-ignored); merged branches can be deleted.

## Environment (owner machine)
- Godot 4.7.2: `%LOCALAPPDATA%\Programs\Godot\` (+ export templates). GitHub CLI: `%LOCALAPPDATA%\Programs\gh\bin\`.
- Node.js 24 + Microsoft Edge for Web smoke tests.

## Next session
Read CLAUDE.md and the M2 handoff. Wait for owner to close M2 and authorize M3; then propose the M3 plan first.
