# DECISIONS.md — Architecture & design decision log

Status values: **APPROVED** (owner said yes), **DELEGATED** (owner asked Lead to decide; revisable),
**WORKING ASSUMPTION** (placeholder until a later phase confirms), **SUPERSEDED**.

| ID | Date | Decision | Status | Source |
|---|---|---|---|---|
| D-001 | 2026-10-19 | Engine is Godot 4 / GDScript per spec. "Web game" is delivered via Godot Web export, not a hand-written HTML/JS game. | APPROVED | Owner Q1 = A |
| D-002 | 2026-10-19 | Concept sheets in `docs/visual/concept/` (style "A + C: Cozy Realistic × Cute & Colorful", chibi characters) are the approved visual direction. | APPROVED | Owner Q2 |
| D-003 | 2026-10-19 | Scale: tile = 64 px; agent clearance classes small = 1 tile (spiders, small creatures), standard = 3 tiles (NPC ~2.5-tile sprite, surface zombie ~3), large = 4+ (bosses). Sprite pivot bottom-center. Stored in `data/config/scale_config.tres`. | WORKING ASSUMPTION | Owner Q3 delegated |
| D-004 | 2026-10-19 | Visual Design Phase runs in parallel with M0. M0 is technical only; art-dependent values isolated in `ScaleConfig`. | DELEGATED | Owner Q4 |
| D-005 | 2026-10-19 | Pin Godot **4.7.2-stable**. Renderer **GL Compatibility** on all platforms (required for Web, safest for Mobile). | DELEGATED | Q5 |
| D-006 | 2026-10-19 | Test framework **GUT 9.7.1**, vendored in `addons/gut/`, run headless via `tools/run_tests.ps1`. | DELEGATED | Q6 |
| D-007 | 2026-10-19 | Basic save/load is moved **into M1** (proposed roadmap change). Each world has two files: `manual.save` and `autosave.save`; atomic write (temp file → rename), keep one previous good copy as `.bak`. Retention beyond that TBD. (World count: see D-014.) | DELEGATED — spec table not edited yet, see OQ-02 | Q7 |
| D-008 | 2026-10-19 | M0–M1: one agent switches roles sequentially. From M2 onward: separate subagents per bounded area, never two on the same files; Lead integrates, QA verifies independently. | APPROVED | Owner Q9 |
| D-009 | 2026-10-19 | Web export is **single-threaded** (`thread_support=false`) so hosts need no COOP/COEP headers. Revisit only with profiling evidence. | DELEGATED | Risk review |
| D-010 | 2026-10-19 | No autoload singletons in M0. Subsystems are owned by the main/session scene and passed explicitly. A single `GameSession` autoload may be proposed later. | DELEGATED | Spec §10 |
| D-011 | 2026-10-19 | Repository: GitHub `game2D-view`, **private** by default (owner can make public). | APPROVED name / DELEGATED visibility | Owner Q8 |
| D-012 | 2026-10-19 | Minimum browser/device specs deferred; must be fixed before M1 closes. | DELEGATED | Q10 |
| D-013 | 2026-10-19 | Core contracts: `CommandResult` (all commands), `StableIdAllocator` ("category:n", never reused, saved), `SimulationClock` (fixed step, Pause/1x/2x/3x, Fast/Normal/Slow cadence; numeric rates are PLACEHOLDERS). | DELEGATED | M0 |
| D-014 | 2026-10-20 | **Up to 3 saved worlds** may be stored (each = its own folder with manual + autosave per D-007). **Only one world is loaded/played at a time** — never simulated concurrently. Creating a 4th is blocked until the player deletes one; delete requires explicit confirmation in UI. Supersedes spec §11 "One world" (spec text update pending, OQ-16). | APPROVED | Owner answer to OQ-14 |
| D-015 | 2026-10-20 | Player never edits terrain directly (ONI-style). Dig/Build tools create **designations** (`DesignationMap`, saved); NPC jobs execute them from M2. Debug builds have an F9 "instant edit" for testing only. | APPROVED | Owner, M1 plan P-1 option A |
| D-016 | 2026-10-20 | M1 plan approved: world presets S 384×192 / M 512×256 (default) / L 1024×384; fog of war → M7; save = `meta.json` + compressed binary with checksum; gen-version mismatch refused; min spec per plan P-6; New World dialog has a name field (required, ≤32 chars, unique). | APPROVED | Owner |
| D-017 | 2026-10-20 | M2 plan approved: start with 3 NPCs; no wall climbing (1-tile steps, drops ≤ 4, ladders); basic construction (ladder + wall, hauled materials) moved from M3 into M2; bundle Noto Sans Thai (OFL); walk ≈ 2 tiles/s placeholder; simulation determinism not required. | APPROVED | Owner, M2 plan P-1…P-6 |
| D-018 | 2026-10-20 | Seeds are random by default: New World dialog pre-fills a random seed and offers re-roll. Seed is still stored per world (saves regenerate unchanged chunks from it). | APPROVED | Owner |
| D-019 | 2026-10-20 | M2 module contracts per `docs/contracts/M2_CONTRACTS.md` (ownership, tick order, APIs, invariants, save v2). | DELEGATED | Lead |

## Rationale notes
- **D-003 clearance 3:** concept sheet shows NPC ≈ 2.5 tiles and ordinary zombie ≈ 3 tiles. A 2-tile corridor
  would force either smaller sprites (contradicts approved art) or zombies that clip ceilings. 3 tiles keeps the
  art, and the small class lets spiders/cave creatures use narrow tunnels — a distinct underground threat (spec §5).
  Cost: players dig more per corridor; revisit after M1 playtest.
- **D-005 Compatibility renderer:** Forward+/Mobile renderers are not available on Web. Using one renderer
  everywhere avoids "works on PC only" visual bugs.
