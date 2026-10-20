# M3 PLAN — Rooms, storage buildings, doors, deconstruction (+ proposed Visual track V1)

**Status:** APPROVED by owner 2026-10-20 (all of P-1…P-5, D-021). Art: B then A with a dedicated Asset Agent
that delivers image-generation prompts; the owner generates the images (D-020).
**Spec §13 M3:** rooms, storage, construction. Acceptance focus: rooms respond to tile edits; structures consume hauled resources.
Basic ladder/wall construction already shipped in M2 (D-017).

## 1. Gameplay scope (agents per D-008)
| # | Item | Owner | Notes |
|---|---|---|---|
| 1 | **Building framework** | Lead (contract) + Systems | `BuildingDef` (size in tiles, materials + kg, work ticks, needs floor), building instances with stable ids, placement validation, build orders using the M2 haul-to-site flow. |
| 2 | **Doors** | World + Colony | 1×3 door in a wall gap; NPCs pass, it counts as wall for rooms. (Locking/zombies = M5.) |
| 3 | **Storage crate** | Systems + Colony | 1×1 building, capacity (e.g. 2000 kg PLACEHOLDER), material filter set in UI; haulers prefer crates over stockpile zones; crates count as storage for rooms. |
| 4 | **Bed, table** (simple furniture) | Systems | Needed so rooms can be classified; no needs effect until M4. |
| 5 | **Room detection** | World | Enclosed air regions bounded by solid tiles/doors, max 128 tiles (PLACEHOLDER; larger = "open cave", not a room). Recomputed only around `tiles_changed` / building changes (dirty regions). |
| 6 | **Room types** | Systems | Bedroom (bed), Storage room (crate), Dining room (table), Generic room. Shown in UI; effects come in M4+. |
| 7 | **Deconstruction** | Colony + Systems | Orders to remove walls, ladders, buildings; NPC works there and **the materials drop on the ground** (P-3 ratio). |
| 8 | **UI** | UI | Build menu (categories), building placement preview (green/red), room overlay with names, crate filter panel, deconstruct tool. |
| 9 | **Save v3** | Lead | Buildings + crate filters; rooms are recomputed on load (not saved). Migration v2 → v3. |
| 10 | **QA** | QA | Independent round as in M2 (stress, save/load, edge cases, Web smoke with the fixed tool). |

## 2. Decisions to approve
| ID | Proposal |
|---|---|
| P-1 | Buildings in M3: **door, storage crate, bed, table**. More come with their systems (kitchen M4, generator M4, turret M5). |
| P-2 | Room = enclosed area ≤ 128 tiles; bigger enclosed spaces are "open cave" (no room bonus). |
| P-3 | Deconstruction returns **100 %** of materials for basic M2/M3 buildings (spec leaves the ratio TBD; a lower ratio can apply to advanced machines/turrets later). |
| P-4 | Haulers prefer storage crates over stockpile zones; stockpile zones stay as a cheap early option. |
| P-5 | Art: start the **Visual track V1** now, in parallel with M3 (section 3). |

## 3. Proposed Visual track V1 (parallel, does not block M3 gameplay)
Goal: replace "programmer art" with readable art that matches the approved concept sheets (D-002).
1. **Asset spec** (Lead + UI, owner approves): exact sprite sizes (tile 64 px; NPC frame e.g. 96×192 px with feet pivot),
   layers, animation list (idle/walk/climb/dig/carry/build — from the miner sheet), file naming, transparent PNG sheets,
   colour palette from the concept sheets.
2. **Art pipeline** (UI): drop PNG files into `assets/production/...` → the game uses them automatically, falling back to
   placeholders when a file is missing. Import test in CI.
3. **First art set**: terrain tiles (dirt, rock, ores, bedrock, concrete, ladder, background wall), 1 NPC body with 3–4
   outfits/role colours, items, stockpile/crate/door/bed/table, UI icons for the toolbar.
4. **Who draws?** Claude cannot produce art at the quality of the concept images. Options for the owner (Q-ART):
   **(A) owner creates sprite sheets with the same image tool used for the concepts, following the spec; Claude slices,
   cleans, imports and wires them;** (B) Claude draws improved vector/pixel-style art in code (more readable than now,
   still far from the concepts); (C) hire an artist with the spec. A + B together is possible: B now as a better
   placeholder, A replaces it when ready.
