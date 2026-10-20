# CLAUDE.md — Project Last Bunker

Godot 4.7.2 / GDScript 2D underground colony sim. Owner communicates in Thai;
reports to the owner are in Thai, code/identifiers/tech docs in English.

## Start of every session (mandatory)
1. Read `PROJECT_MASTER_SPEC.md` (authoritative design; never edit without owner approval).
2. Read `docs/PROJECT_STATE.md` and `docs/MILESTONE_HANDOFF.md`.
3. Check `docs/ROADMAP.md` for which milestone is **authorized**. Only work inside it.
4. Check `docs/DECISIONS.md` and `docs/OPEN_QUESTIONS.md` before assuming anything.

## Hard rules
- Never start, or implement features of, a milestone the owner has not authorized.
- Never claim tests passed without running them; mark anything unexecuted **NOT RUN**.
- Every new design choice → `docs/DECISIONS.md`. Every doubtful/ambiguous item → `docs/OPEN_QUESTIONS.md`.
- Gameplay values that depend on art (pixels, clearances) come from `data/config/scale_config.tres`, never hard-coded.
- UI never mutates game state directly: it calls commands that return `CommandResult`.
- No global singletons beyond what DECISIONS.md approves (currently: none).
- Separate definitions (`data/defs/`) from runtime instances; IDs come from `StableIdAllocator`.
- Placeholder art lives only in `assets/placeholder/` and must look obviously placeholder.
- Finish every milestone with `docs/MILESTONE_HANDOFF.md` (10 sections, spec §15) and stop at
  **STATUS: AWAITING OWNER REVIEW / APPROVAL**.

## Module ownership (spec §10, §14)
| Path | Owner role |
|---|---|
| `project.godot`, `export_presets.cfg`, `src/core/`, `docs/`, `CLAUDE.md` | Lead Architect |
| `src/world/` | World Agent |
| `src/navigation/`, `src/jobs/`, `src/colony/` | Colony/NPC Agent |
| `src/inventory/`, `src/infrastructure/` | Systems Agent |
| `src/combat/` | Combat Agent |
| `src/exploration/` | Exploration Agent |
| `src/progression/` | Lead (until a dedicated role is assigned) |
| `src/persistence/` | Lead (contracts) + each module's snapshot functions |
| `src/presentation/` | UI/UX Agent |
| `tests/`, `docs/TEST_PLAN.md` | QA Agent (may block closure) |

Agents may not edit another role's paths concurrently. Cross-module change = contract change via Lead.

## Commands
```
powershell -File tools/run_tests.ps1                  # import + full GUT suite, exit!=0 on failure
powershell -File tools/export.ps1 -Preset Web         # build/web/
powershell -File tools/export.ps1 -Preset "Windows Desktop"
node tools/serve_web.js 8060                          # http://localhost:8060
node tools/web_smoke.mjs steps.json out_dir [profile] # drive Web build in headless Edge (screenshots)
godot --headless --path . -s res://tools/bench_world.gd   # generation/save benchmark
```
Any change to `WorldGenerator` output must bump `GEN_VERSION` (golden-hash test guards this).
The browser pane in the desktop app may be hidden (no frames render) — use `web_smoke.mjs` for Web checks.
Write files with UTF-8 (PowerShell 5.1 `Get-Content`/`Set-Content` corrupt non-ASCII; use the Edit tool).
Godot binary: `%LOCALAPPDATA%\Programs\Godot\Godot_v4.7.2-stable_win64_console.exe` (override with `$env:GODOT`).
