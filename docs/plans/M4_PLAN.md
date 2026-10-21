# M4 PLAN — Basic needs, food, power, water, room oxygen

**Status:** PROPOSED — awaiting owner approval (gate G2). No M4 code until approved.
**Spec §13 M4:** basic needs, food, power, water, room oxygen. Acceptance focus: *essential survival loop playable*.
Spec refs: §3 (needs, schedules, refuse unsafe orders), §4 (power/water/oxygen per room, overlays), §9 (alerts), §1 (recoverable setbacks).

## 0. Proposal: split into two milestones (P-1)
M4 is the largest milestone so far (five systems). To keep QA meaningful and review gates small:
| Part | Scope | Survival loop after it |
|---|---|---|
| **M4a — Time, needs, food** | day/night clock, schedules, hunger, sleep, health, alerts, farming, kitchen, eating, beds used for sleep | colonists must be fed and rested |
| **M4b — Power, water, oxygen** | wires, generator, battery, consumers; pipes, water pump, tank; per-room oxygen, oxygen generator, suffocation | sealed bases need air, power and water |

## 1. M4a scope
| # | Item | Notes (PLACEHOLDER numbers) |
|---|---|---|
| 1 | **Day/night clock** | 1 in-game day = 10 real minutes at 1x (600 s = 6000 ticks); HUD shows Day N, hh:mm. Surface darkens at night (visual only in M4). |
| 2 | **Schedules** (spec §3) | Per-NPC 24-hour schedule, each hour Work / Sleep / Free; default 06–22 work, 22–06 sleep. Simple editor (grid of 24 buttons) in the NPC inspector + "apply to all". |
| 3 | **Needs** | Hunger (0–100, eat when < 40), Sleep/stamina (sleep in a bed during Sleep hours or when exhausted; floor sleep = slower + small stress later), Health (drops when starving / exhausted, recovers when needs are met). Stress/hygiene/comfort/happiness → M9. |
| 4 | **Setbacks** (P-2) | No instant death: a starving or exhausted NPC **collapses** (incapacitated, cannot work) with an emergency alert; it recovers if fed/rested by others; it dies only after a long time untreated (≈ 1 in-game day collapsed). Death drops carried items; other NPCs are notified (mood effects come in M9). |
| 5 | **Food** | Crops: **Farm plot** building (2×1) grows *cave mushrooms* (needs water from M4b? → see P-3), harvested by NPCs (new job type *Farm*), produces raw food items. **Kitchen** building cooks raw food → *meal* items (job *Cook*). Eating: NPC fetches a meal (from crate/ground), eats at a **table** if one is free (faster/better), otherwise standing. Starting supply: one crate of rations at world start. |
| 6 | **Beds** | Beds become assignable/owned (auto-assign); bedroom room type gives better rest (small bonus). |
| 7 | **Alerts** (spec §9) | General / important / emergency list (top-right), with click-to-locate. Hunger, exhaustion, collapse, no food left, no free bed. |
| 8 | **NPC refuses unsafe orders** (spec §3) | Collapsed or critically hungry NPCs refuse work/move commands with a clear reason. |
| 9 | **Save v4** | needs, schedules, crops, food items, alerts. Migration v3 → v4 (NPCs start fed and rested). |
| 10 | **UI** | Needs bars in inspector, schedule editor, colony overview (all NPCs + needs), farm/kitchen panels, day/time HUD. |

## 2. M4b scope (planned now, approved separately after M4a)
Utility layers (wires, pipes) as separate grids; power networks (generator → wire → battery → consumers, brownouts);
water (pump from a groundwater source building, pipes, tanks); oxygen per room (O2 level per room, NPC consumption,
oxygen generator using power + water, suffocation → collapse); overlays for power / water / oxygen.

## 3. Decisions to approve
| ID | Proposal |
|---|---|
| P-1 | Split M4 into **M4a** (time, needs, food) and **M4b** (power, water, oxygen). |
| P-2 | **No instant death:** collapse first, death only after ~1 in-game day untreated (recoverable setbacks, spec §1). |
| P-3 | M4a crops do **not** need water yet (cave mushrooms grow on dirt in darkness); M4b adds water-hungry crops. Keeps M4a independent of M4b. |
| P-4 | 1 day = 10 real minutes at 1x; default schedule 06–22 work, 22–06 sleep. |
| P-5 | Needs in M4: hunger, sleep, health only. Stress, hygiene, comfort, happiness, relationships → M9 (spec roadmap). |
| P-6 | Start a new world with 1 crate of rations (≈ 3 days for 3 NPCs). |

## 4. Acceptance (M4a)
1. With no farms, a colony runs out of food and NPCs collapse with alerts; feeding them recovers them (no instant death).
2. With farms + kitchen built from hauled materials, a 3-NPC colony survives 10 in-game days unattended at 3x.
3. NPCs follow schedules (sleep in owned beds at night), and needs/schedules survive save/load mid-action.
4. All M0–M3 invariants (no double claims, kg conservation incl. food) still hold; 100-NPC bench stays well under 100 ms/tick.
5. Web smoke with real browser restart.

## 5. Work split (D-008)
Lead: contracts (time, needs, food items, schedule, alert APIs), save v4. **Colony Agent:** needs, schedules, eat/sleep/
farm/cook jobs, collapse/death. **Systems Agent:** crops, kitchen recipes, food items, alert service. **World Agent:**
farm plot / kitchen building defs. **UI Agent:** HUD clock, alerts panel, needs bars, schedule editor, colony overview.
**QA Agent:** independent round. Art (parallel, D-027): Asset Agent.
