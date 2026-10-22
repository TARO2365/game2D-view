# CLAUDE.md — Project Last Bunker

Godot 4.7.2 / GDScript 2D underground colony sim. Owner communicates in Thai;
reports to the owner are in Thai, code/identifiers/tech docs in English.

## Session start (keep it cheap — tokens matter)
Read **only `PROGRESS.md`** at session start. Open other docs **only when the task needs them**, and only the relevant part
(use Grep / read a section, not whole files):
| Need | Open |
|---|---|
| Planning a new milestone | the matching section of `PROJECT_MASTER_SPEC.md` (§13 roadmap + that topic) and `docs/plans/` of the previous milestone as a template |
| Editing a module | its contract in `docs/contracts/` (latest `M4A_CONTRACTS.md`) — grep the class/section |
| "Was X decided?" | grep `docs/DECISIONS.md` / `docs/OPEN_QUESTIONS.md` for the keyword |
| Details of a past milestone | `docs/handoffs/` (M0–M3) or `docs/MILESTONE_HANDOFF.md` (M4a) |
Run `tools/run_tests.ps1` only before/after code changes (filter its output), not for status questions.

## Working practice
- Milestone flow: owner OK → plan → owner OK → contracts → role agents in separate worktrees → Lead merges and re-runs
  tests itself → QA round → fixes → handoff (Thai report, ends "STATUS: AWAITING OWNER REVIEW / APPROVAL").
- Token economy: give agents short briefs that point to files (they read them), don't paste docs; ask for short reports.
- Agents often hit usage limits: resume them with a message, ask them to commit in parts.
- Owner AI images usually land in `C:\Users\Taro1123\Documents\ChatGPT\asset ai\assets\incoming` → copy to
  `assets/incoming/` (git-ignored) → `tools/art_import.gd`. Never commit raw images.
- A `node` process under `.cache\codex-runtimes` is the owner's Codex — never kill it.

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
| `assets/`, `docs/art/` (asset spec, prompt packs), `src/presentation/art/`, `placeholder_tiles.gd`, `npc_view.gd`/`item_view.gd` drawing code | Asset Agent (D-020) — writes image-generation prompts for the owner; never claims AI images exist until the owner supplies them |

Agents may not edit another role's paths concurrently. Cross-module change = contract change via Lead.

## Commands
```
powershell -File tools/run_tests.ps1                  # import + full GUT suite, exit!=0 on failure (also on unloadable scripts)
powershell -File tools/run_stress.ps1                 # slow stress suite (tests/stress)
godot --headless --path . -s res://tools/bench_npcs.gd    # 100-NPC tick benchmark
godot --headless --path . -s res://tools/qa_bench.gd -- 600   # QA perf scenarios (crates, unreachable, items)
godot --headless --path . -s res://tools/art_import.gd -- --src <dir with raw owner images>   # import AI art
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
