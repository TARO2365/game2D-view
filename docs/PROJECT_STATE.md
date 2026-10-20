# PROJECT_STATE.md

**Updated:** 2026-10-20 | **M0:** Closed | **M1:** In review (awaiting owner closure) | **Next authorized:** none

## What exists (playable)
- App shell: main menu with up to 3 stored worlds (one played at a time), New World dialog (name, seed, size), delete with confirmation.
- Finite seeded world (Small/Medium/Large) with dirt, rock, iron, gold, crystal, bedrock border; deterministic on PC and Web.
- Chunk-streamed rendering with runtime placeholder tiles; camera pan/zoom.
- Player **orders** (dig / build wall / cancel) — terrain only changes via debug F9 instant edit until NPCs arrive in M2 (D-015).
- Manual save, autosave (5 min + on Menu), atomic writes with `.bak` fallback, only changed chunks saved.
- Speed control Pause/1x/2x/3x, debug HUD (FPS, tick, chunks, orders, world hash, cursor tile).
- 76 automated tests; benchmark tool; headless-browser Web smoke tool.

## What does NOT exist yet
NPCs, jobs, hauling, inventory/materials, ladders, navigation, rooms, deconstruction, caves, fog of war, real art, sound, Thai UI.

## Repository
https://github.com/TARO2365/game2D-view (branch `main`). Git auth via Git Credential Manager; `gh` CLI not logged in.

## Environment (owner machine)
- Godot: `%LOCALAPPDATA%\Programs\Godot\` (+ export templates in `%APPDATA%\Godot\export_templates\4.7.2.stable`)
- GitHub CLI: `%LOCALAPPDATA%\Programs\gh\bin\gh.exe` (both added to user PATH)
- Node.js 24 (Web server + headless Edge smoke test). Microsoft Edge used for Web smoke tests.

## Next session
Read CLAUDE.md and `docs/MILESTONE_HANDOFF.md`. Wait for owner to close M1 and authorize M2; then propose the M2 plan first.
