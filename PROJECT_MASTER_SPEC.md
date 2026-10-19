# PROJECT LAST BUNKER
## Master Specification for Claude Code
**Status:** Approved design baseline; pre-production, not implementation authorization  
**Version:** 0.1 | **Language:** English technical specification with Thai owner notes  
**Engine:** Godot 4 / GDScript | **Primary platform:** PC | **Targets for early compatibility testing:** Web, Mobile

> **OWNER NOTE (TH):** เอกสารนี้เป็นข้อกำหนดกลางให้ Claude Code อ่านก่อนทำงาน ไม่ใช่คำสั่งให้เริ่มเขียนเกมทั้งหมดทันที ทุก Milestone ต้องขออนุมัติก่อนเริ่ม และตรวจงานก่อนส่ง

## 0. Operating contract: read first

1. This file is the authoritative *design baseline*, not blanket permission to implement features.
2. **Do not implement any milestone until the owner explicitly authorizes that milestone.** Do not begin the next milestone after completing the current one without approval.
3. At the start of each authorized milestone: inspect the repository, current project state, interfaces, tests and dependencies; propose a scoped implementation plan and obtain approval for significant scope changes.
4. Never silently introduce mechanics, rewrite unrelated modules, change architecture, or claim an untested feature works.
5. Before delivery: run feasible automated tests, launch the relevant Godot scene/build when possible, perform regression checks, inspect changed files/diff, and report evidence and limitations. Tests not run must be explicitly marked **NOT RUN**.
6. Assign specialist agents bounded responsibilities. The lead integrates; QA independently reviews. Agents must not modify overlapping files concurrently without coordination.
7. Use Git checkpoints/commits, document changes, unresolved risks and exact next steps. A new Claude Code chat/session starts by reading this file and the latest handoff.
8. Keep design decisions distinct from implementation assumptions. Anything labeled **PROPOSED**, **TBD**, or **VALIDATE** is not locked.
9. **Visual assets are pending a separate Visual Design Phase.** Use clearly identified placeholders only when the owner authorizes prototyping.
10. Never state “milestone complete” unless acceptance criteria and evidence are satisfied and the owner approves closure.

## 1. Vision / วิสัยทัศน์
A single-player, 2D side-view, tile-based underground colony simulation with zombie-apocalypse survival. The primary joy is digging, constructing, organizing, automating and gradually growing a comfortable underground kingdom. Zombies and exploration add pressure and variety without overpowering colony building. Inspired in interaction clarity and colony depth by Oxygen Not Included, but original art, UI and mechanics are required.

- Gameplay orientation: colony construction/management dominant, defense secondary, story optional.
- High-detail 2D cartoon with serious atmospheric treatment; *not* the earlier bright/cutesy-only art direction. Visual direction is not finalized until Visual Design.
- Recoverable setbacks preferred over arbitrary instant game-over.
- No multiplayer planned.
- PC-first release; test Web and Mobile constraints from the beginning. Mobile-specific production polish may be staged.
- Working title only: **Project Last Bunker**.

## 2. Locked world and time model
- Large **finite** world with deterministic seed-based procedural generation at creation; player may build throughout reachable map. Seed and generation version must be recorded.
- Continuous side-view tile world with digging, constructing, natural caves, resources, underground facilities and different geological strata.
- Chunk-based rendering/loading; separate visual streaming from gameplay simulation. Offscreen agents cannot freeze merely because camera moved away.
- Player controls Pause / 1x / 2x / 3x.
- Fixed-step simulation with **Fast / Normal / Slow** subsystem update cadences; rates and budgets **TBD by profiling**.
- Dirt/rock stability: long unsupported tunnels or large cavities need supports/linings. Provide cracks/dust/warnings and recovery time; collapse may block routes, injure workers or trap vehicles. Forgiving near surface, harder at depth.
- Soft fog of war: rough silhouettes and clues visible; exact details revealed by exploration.
- World changes invalidate affected navigation, room topology, utilities, stability and overlays via dirty-region/event mechanisms rather than full-world recompute.

## 3. Colony, NPCs and jobs
- Target: **100 NPCs** in a large late-game colony, using simplified AI/LOD where safe; target is an optimization objective, not a guaranteed benchmark.
- Random Thai full names and nicknames, avoid duplicate generated names; randomized backstories, personality traits and aptitudes.
- NPCs can perform all ordinary jobs, with differing aptitude, skill gains through practice, and spendable skill points/abilities.
- Needs: food, sleep, health, hygiene, happiness, comfort, stress; relationships/friendships/conflicts.
- Player-editable 24-hour schedules; overtime can increase fatigue, stress and errors. NPCs may refuse unsafe orders in critical conditions.
- Conditions, wounds, illnesses and infections require condition-specific treatment.
- Jobs have global and per-NPC priorities; tasks and physical materials must be reserved atomically to avoid double assignment/duplication.
- NPCs physically move, collect materials, carry to destination and perform construction, repairs, production and hauling. No instant material teleportation.
- Quick commands: move here, stop job, return to base; autonomous work remains default.
- Survivors can be rescued/recruited via events and discovered bunkers. Death impacts others.
- NPC combat is autonomous with player position/defense orders.
- **Ownership invariant:** Job Manager owns job lifecycle/reservations; Inventory owns material quantities; NPC AI owns intent and movement, not direct inventory mutations.

## 4. Rooms, infrastructure, production
- Rooms detected automatically from enclosed geometry and relevant fixtures; losing room function does not erase physical geometry.
- Electricity: generators, wiring, batteries, consumption, networks.
- Water: pipes, tanks, delivery networks. Oxygen simulated **per room**, with ventilation and connections; not per-tile gas simulation.
- Food: farming, kitchens, recipes, consumption and storage.
- Production recipes, target stock quantities, priorities, queues, hauling and real storage.
- Ladders, elevators and cargo movement.
- Buildings have damage, repairs, periodic wear/maintenance, and modular upgrades. Machines support detailed module customization; earlier simple speed/efficiency/durability upgrade idea is subsumed by module-based design.
- Advanced automation: sensors, switches, doors, control circuits, logic gates. Circuit update loops must be bounded/detected.
- UI overlays: power, water, oxygen, heat, sound, pathing, safety/stability, job priority. Only compute/render expensive overlay details when requested or invalidated.

## 5. Combat and threats
- Ordinary **surface zombies** spawn near map edges and walk toward the bunker. **They cannot dig earth.** They must break surface access/entrances, doors or gates, then physically navigate down accessible corridors.
- Underground threats are distinct: mutated/zombie animals and cave creatures; **some can tunnel toward nearby noise**. Do not grant this to normal surface zombies.
- Horde every **5 in-game days**, with warning one day in advance. Scale with time, progression, and capped Threat Level; avoid runaway punishment for improving defenses.
- Boss encounters around every 10–15 days, subject to final pacing balance.
- Turrets can be placed at valid positions throughout the bunker with line of sight; require electricity, ammunition, range, upkeep; ammo manufactured and physically delivered by NPCs.
- Weapon families: machine gun, laser, rocket, electrical. Defense: walls, doors, mines, traps, electric fences.
- Turrets have upgrade modules, but researched next-generation turret chassis outperform old chassis in overall potential. Old turrets may remain efficient/low-maintenance. Dismantling may reclaim part of material, exact ratio **TBD**.
- Separate surface Threat Level from underground disturbance/noise where useful; emergency repair priority after attacks.
- Difficulty presets (Relaxed/Standard/Hardcore) were **proposed**, not explicitly confirmed; leave configurable architecture but do not treat presets as locked content.

## 6. Mining vehicles, exploration, underground ecology
- Vehicles perform direct tile-by-tile digging and designated-area dig orders, with queues such as dig/explore/collect/return.
- **NPC driver required**: worker physically boards, operates and leaves vehicle; vehicle not autonomous-only.
- Electric and fuel vehicles, garage/parking/service/charge/refuel stations.
- Replaceable drill heads, engine, battery and radar modules.
- Generated facilities include survivor shelters, military bases, research labs, food warehouses, factories and abandoned train/subway stations.
- Captured bunkers connect into **one integrated colony**, not separately simulated rival settlements.
- Expeditions carry risk; survivors/loot/vehicles and recovered items must physically return.
- Underground ecology and food chains exist but offscreen simulation must be budgeted/abstracted.
- Rewards: special weapons, data, vehicles, survivors and equipment.

## 7. Research, technology, robots
- Seven main research branches: Mining, Energy, Engineering, Defense, Medical, Survival, Exploration, plus cross-branch technologies.
- **7+ tiers** for long-form progression; exact node counts and prerequisites **TBD**.
- Research conducted by NPCs in powered laboratories over time. Unlocks require research points and prerequisites. Blueprint is buildable immediately after research (assuming normal material requirements).
- Rare technologies found through exploration and bosses; do not gate indispensable early survival behind random rare loot.
- Virus research supports treatment and weapon development.
- Modular machines and turrets; new researched turret generations superior to upgrades of prior generations.
- Advanced logic automation.
- Robots may perform selected repetitive work: cargo, repair, mining, cleaning/utility. Robots use power, maintenance, pathing, storage/job integration; do not fully replace human medical/research roles.
- Technology pace tracks colony growth, not rush to max tier.

## 8. Story, quests and endgame
- Secret experimental-virus origin; **5 chapters**: Shelter, Beneath the Ruins, Forgotten Network, Origin, Last Decision (working chapter names).
- Delivery via dialogue, events and discoveries.
- Story is optional Sandbox enrichment, not the primary play loop; main quests are undertaken when ready, not compulsory timers.
- Choices affect NPCs, resources and narrative. Events concern base, expeditions and survivors.
- Rescue missions can recruit NPCs; rewards include rare equipment, NPCs and technologies.
- Multiple endings based on decisions. After ending, keep playing the same colony in late-game Sandbox.
- No simulated rival factions or independent kingdoms required.
- Include **World Journal** and **Event Timeline**, plus Colony Statistics/resource graphs.
- Colony Prestige scoring was only a proposal; **not locked**.

## 9. UI/UX and accessibility
- Detailed management-style information windows, readable icons, easy clickable controls inspired by ONI's usability, without copying its visual assets or interface wholesale.
- Pan/zoom freely; drag-select digging/building areas; contextual entity inspector and NPC quick commands.
- Unified game data/commands underlying PC/Web/Mobile UI, with responsive layout and input adaptation.
- Alert severities: general, important, emergency.
- Overlays for infrastructure, heat, noise, navigation and safety; ensure clear legends and contextual help.
- Prioritize readable UI and usable touch targets, including zoom/pan gestures and non-overlapping panels. Exact dimensions **TBD during UX prototype**.
- Do not implement separate gameplay logic in UI widgets; UI issues validated commands and observes game state.

## 10. Architecture and ownership contracts
Use Godot 4 and GDScript. Prefer modular composition, clear ownership, typed interfaces and signals/events where appropriate. Do **not** make every subsystem a global singleton.

Suggested boundaries:
- `World`: generation, chunk state, tile edits, geology.
- `SimulationClock`: fixed ticks and rate scheduling.
- `Navigation`: paths, dirty nav regions, movement constraints.
- `JobManager`: jobs, priorities, reservations and assignment.
- `Colony`: NPC needs, traits, skills, schedules, social state.
- `Inventory/Production`: stock, recipes, physical transfers, crafting.
- `Infrastructure`: power, water, room oxygen, heat and automation.
- `Combat`: surface zombies, cave threats, horde director, weapons.
- `Exploration`: vehicles, garages, expeditions, discoveries.
- `Progression`: research, quests, story flags.
- `Presentation`: scenes, animation, camera, audio, UI/overlays.
- `Persistence`: save snapshots, load/migration, autosave.

**Integration invariants**
- One canonical source of truth for each mutable entity/resource.
- Explicit stable IDs for tiles/chunks, NPCs, items, structures, vehicles, jobs and quests.
- Every command validates prerequisites and returns a clear success/failure result.
- Cross-module changes are events or contract-defined calls, not direct edits to foreign internal state.
- World edits propagate invalidations only to affected regions.
- Save/load preserves in-flight jobs, reservations, carried items and vehicles without duplication.
- Separate definitions (items, buildings, research, recipes, enemy types) from runtime instances.
- Profile before choosing exact simulation rates, chunk sizes, path budgets and entity limits.

## 11. Persistence
- **One world with Manual Save and Autosave.** Do not assume multiple named save slots, cloud saves or mandatory export/import are approved.
- Persist seed, generation version, changed terrain/chunks, world clock, inventories, jobs/reservations, NPC state, vehicles, research, quests, story choices, infrastructure, horde state, camera/UI preferences as appropriate.
- Snapshot only at a coherent simulation boundary; write atomically where supported, verify integrity and recover gracefully from corrupt/incomplete saves.
- Include `save_version` and migration strategy. Backup retention is **TBD**: earlier general preference mentioned backups, but final selection specifically names manual + autosave.
- Web browser persistence limitations and optional export/import need feasibility review, not automatic scope expansion.

## 12. Performance and QA
- PC-first performance target, with Web/Mobile smoke tests from early milestones.
- Validate ~100 NPCs and increasing zombie populations using stress scenarios; precise frame-rate, RAM and entity budgets **TBD from benchmarks**.
- Separate simulation from render FPS, bound per-tick workloads, avoid repeated whole-world pathfinding/topology updates.
- Tests: unit, integration, regression, scene launch, save/load round-trip, deterministic seed/world generation checks, stress tests for NPC and zombies.
- Test failure blocks milestone closure; environment limitations are reported honestly, not hidden.
- Track FPS, tick time, memory, nav requests, active entities and save time where feasible.

## 13. Milestone roadmap (proposed delivery sequence, approval required per step)
| Stage | Scope | Acceptance focus |
|---|---|---|
| M0 | Project scaffold, contracts, test harness, initial art assumptions | Godot project opens, tests run, scope and ownership documented |
| M1 | Tiles, finite seeded world, chunks, camera, basic dig/build | Deterministic world, tile edits persist, pan/zoom and commands work |
| M2 | NPC movement, job queue, reservations, hauling | No duplicate job/material claims; NPC physically transports goods |
| M3 | Rooms, storage, construction | Rooms respond to tile edits; structures consume hauled resources |
| M4 | Basic needs, food, power, water, room oxygen | Essential survival loop playable |
| M5 | Surface zombies, entry damage, doors, basic turret, horde | Correct zombie path rules and defense loop |
| M6 | NPC-driven vehicles, garage, digging/exploration | Driver/vehicle lifecycle and resources consistent |
| M7 | Caves, bunkers, underground creatures, tunnel stability | Discovery, distinct tunneling threat, warning/collapse behavior |
| M8 | Research, automation, modular upgrades, robots | Dependencies and integrated production/robot jobs work |
| M9 | NPC social/medical depth, wear/maintenance | State transitions and maintenance regression tests |
| M10 | Quest/story chapters and multiple endings | Optional story, persistent choices, post-ending Sandbox |
| M11 | Full UI polish, responsive controls, sound, finalized art | Functional, accessible interfaces on target screens |
| M12 | Optimization, save compatibility, platform QA/export | Documented performance and build test evidence |

**Important:** A minimal UI and working save/load must arrive in early milestones, not wait until M11/M12. Visual Design should establish a baseline before art-dependent M0/M1 decisions. The above ordering is a proposal; scope can be rebalanced only with owner approval.

## 14. Specialist agent roles
- **Lead / Architect:** owns milestone plan, interface consistency, merges, dependency review and owner approvals.
- **World Agent:** tile/chunk/world generation, geology, stability and world events.
- **Colony Agent:** NPC needs, skills, job assignment and reservations.
- **Systems Agent:** production, power, water, oxygen and automation.
- **Combat Agent:** zombie rules, hordes, turrets, bosses and threat scaling.
- **Exploration Agent:** vehicles, garages, expedition and bunkers.
- **UI Agent:** UX, controls, overlays, stats and accessibility.
- **QA Agent:** independent test planning, regression, performance and verification; should not rubber-stamp implementation.

Use only roles relevant to current approved scope. Lead controls shared files; QA can flag and block closure. No agent can independently approve the next milestone.

## 15. Mandatory milestone handoff template
Every completed milestone must report:
1. Approved scope and acceptance criteria.
2. Files added/modified, notable decisions and interface changes.
3. Actual implemented behavior with reproduction steps.
4. Tests executed with commands, outcomes, and evidence; explicit **NOT RUN** items.
5. Regression findings, performance observations, bugs and known limitations.
6. Save compatibility impact, if any.
7. Git revision/commit or diff summary.
8. Items deliberately deferred or out of scope.
9. Current project state and instructions for next session.
10. **Status: AWAITING OWNER REVIEW / APPROVAL.**

## 16. Visual Design Phase: pending, separate
After this specification is reviewed, the owner wants to design the actual game visuals **before substantial gameplay production**:
- Original style guide: high-detail cartoon, serious atmosphere, readable underground cross-section.
- Character proportions, silhouettes, animation vocabulary; surface zombies vs cave creatures.
- Tilesets/biomes, room structures, machines, modular turrets, vehicles, garage, UI iconography.
- Asset pipeline: grid/tile dimensions, sprite scale, camera zoom, layering, pivots, atlases/spritesheets, animations, export conventions and Godot import tests.
- First create visual concepts and a representative gameplay mockup, then approve an asset specification before production assets.
- No exact pixel dimensions or art deliverables are locked yet.

## 17. Outstanding decisions / TBD
These are **not** blockers to completing this design baseline, but must be resolved before affected milestones:
- Final game title and original visual identity.
- Tile pixels/world dimensions/chunk dimensions and actual memory budgets.
- Fast/Normal/Slow tick frequencies and precise deterministic requirements.
- Initial NPC count, recruitment pacing, maximum simultaneous combat units and Horde balance.
- Save backup retention, recovery behavior and Web persistence UX.
- Power/water/oxygen numerical balance, heat and sound simulation granularity.
- Turret modules, upgrade costs, robot capacities and research tier content.
- Mobile touch interaction details and supported minimum device/browser specifications.
- Final UI mockups, sprite conventions, animations and audio.
- Legal originality review of assets/UI references.
- Explicit owner authorization of M0 and subsequent milestones.

## 18. Owner-facing summary (ภาษาไทย)
เกมนี้เน้นความเพลินจากการขุด สร้าง และขยายฐานใต้ดินเป็นอาณาจักร มี NPC ทำงานและขนของจริง มีระบบไฟ น้ำ ออกซิเจน ฟาร์ม วิจัย รถขุด ป้อมปืน หุ่นยนต์ และภัยจากซอมบี้ด้านบนกับสิ่งมีชีวิตใต้ดินคนละประเภท โลกมีขนาดจำกัดแต่ใหญ่ สร้างด้วย Seed เป้าหมายฐานใหญ่ NPC 100 คน ใช้ Godot 4/GDScript โดย PC เป็นแพลตฟอร์มหลัก ทดสอบ Web/Mobile ตั้งแต่ต้น

Claude Code ต้องอ่านเอกสารนี้ก่อน แยกงานตาม Agent แต่ละตัว มีหัวหน้าประสานและ QA ตรวจจริง **ห้ามข้าม Milestone ห้ามทำล่วงหน้า ห้ามอ้างว่าทดสอบผ่านโดยไม่มีหลักฐาน และต้องรอเจ้าของอนุมัติก่อนเริ่มขั้นถัดไป** หลังสรุปข้อกำหนด จะเข้าสู่การออกแบบภาพเกมจริงก่อนผลิต Asset และเริ่มพัฒนาอย่างเป็นระบบ
