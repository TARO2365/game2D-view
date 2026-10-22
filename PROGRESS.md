# PROGRESS.md — Project Last Bunker

**Updated:** 2026-10-22 | **Latest closed:** M4a | **Next:** M4b (power, water, oxygen) — not planned yet, awaiting owner go-ahead
Details per milestone: `docs/handoffs/` (M0–M3) and `docs/MILESTONE_HANDOFF.md` (M4a). Decisions: `docs/DECISIONS.md`.

## ✅ Done (closed by owner)
| Milestone | Delivered |
|---|---|
| M0 | Godot 4.7.2 project, core contracts, GUT test harness, Web/Windows export, project docs |
| M1 | Seeded finite world (S/M/L), chunk streaming, camera, player orders (ONI-style, D-015), save/load with up to 3 worlds (D-014) |
| M2 | 3 NPCs with Thai names, pathfinding (steps/drops/ladders), jobs with reservations, hauling to stockpiles, ladder/wall construction, item gravity, save v2 |
| M3 | Build menu (door, crate, bed, table), rooms (bedroom/storage/dining), deconstruction (100 % refund), crates with filters, save v3 |
| M4a | Day/night clock (worlds start 06:00), needs (hunger/stamina/health), collapse before death, 24-h schedules, farm plot + kitchen + eating at tables, beds, feeding collapsed NPCs, 3-level alerts, colony overview, night tint, save v4 |
| Art (D-020/D-027) | Owner AI art batches 1–2 in game (characters, terrain, sky, cave wall, buildings, items, icons), ONI-style terrain rendering, animation fixes, skeletal rig pilot, prompt packs |

**Quality at M4a close:** 542/542 tests, 8/8 stress, 100 NPCs with needs ≈ 2.5 ms/tick (budget 100 ms), Web save → real browser restart → load verified.

## ⚠️ Open issues (carried forward)
1. **Slow first Web launch (OQ-20):** in a fresh browser profile the first world runs at ~1–4 FPS (headless, software rendering) until shaders are cached; later runs 11–39 FPS. Needs a real-GPU check and possibly shader pre-warming.
2. **Skeletal rig still rough:** limbs look disjointed because parts are auto-cut from old sheets. Waiting for the owner's `rig_miner_parts.png` (prompt in `docs/art/PROMPTS_V2_RIG.md` §1); modular citizens are designed but not coded.
3. **Missing art:** icons `build_menu`, `deconstruct`, `rooms`; `farm_plot` and `kitchen` buildings; food items `mushroom`, `meal`, `ration` — code-drawn fallbacks are used until then (`docs/art/MISSING_V1.md`).
4. **NPC name labels overlap the toolbar** when an NPC stands near the top of the screen (cosmetic).

## ➡️ Next
**M4b — power, water, room oxygen** (wires/generator/battery, pipes/pump/tank, per-room O2 and suffocation, overlays).
Plan not written yet — will be proposed for approval when the owner asks.
