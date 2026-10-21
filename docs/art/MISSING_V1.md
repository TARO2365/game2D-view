# MISSING_V1.md: art still needed after batch 1

> **สำหรับเจ้าของโปรเจกต์:** ชุดแรก 35 ภาพนำเข้าเกมแล้ว (ดินและแร่ 5 ชนิด, บันได, ตัวละคร 4 อาชีพ ท่าเดินและขุด,
> ช่างขุดท่าแบกและปีน) ด้านล่างคือรายการที่ยังขาด เรียงจากสิ่งที่เห็นบนจอมากที่สุดไปน้อยที่สุด
> แต่ละข้อบอกหัวข้อ prompt ใน `docs/art/PROMPTS_V1.md` ที่ต้องใช้ ส่งกลับที่ `assets/incoming/` ด้วยชื่อในคอลัมน์ "Send as"
> ระหว่างที่ยังไม่มีภาพ เกมใช้ภาพสำรองให้อัตโนมัติ (ดูคอลัมน์ "Until then")

Batch 1 imported on 2026-10-21 with `tools/art_import.gd`:
- `terrain_{dirt,rock,iron_ore,gold_ore,crystal}` (made seamless; variants share borders)
- `ladder`
- `npc_{miner,technician,scientist,cook}_{walk,dig}`
- `npc_miner_carry`, `npc_miner_climb`

| # | Send as | Prompt section | Until then | Why it matters |
|---|---|---|---|---|
| 1 | `backwall_dug_v1..v4` | §2.1 (background wall) | flat dark colour | every dug tunnel/room shows it; biggest flat area on screen |
| 2 | `sky_surface` | §3 | flat purple colour | top third of the screen at the start |
| 3 | `terrain_bedrock_v1..v4` | §2 table, row `terrain_bedrock` | code-drawn tile | world floor; looks different from the AI tiles beside it |
| 4 | `terrain_concrete_v1..v4` | §2 table, row `terrain_concrete` | code-drawn panel | every built wall (Build wall tool) |
| 5 | `npc_miner_idle`, `npc_technician_idle`, `npc_scientist_idle`, `npc_cook_idle` | §4 template, row `idle` (4 frames) | one still walk frame | NPCs stand idle most of the time; the still frame looks frozen |
| 6 | `npc_technician_carry`, `npc_scientist_carry`, `npc_cook_carry` | §4, row `carry` | their walk cycle + item chunk | hauling is the most common job after digging |
| 7 | `npc_technician_climb`, `npc_scientist_climb`, `npc_cook_climb` | §4, row `climb` | their walk cycle on the ladder | every vertical move |
| 8 | `building_door`, `building_crate`, `building_bed`, `building_table` | §6 | code-drawn buildings | M3 rooms |
| 9 | `item_dirt`, `item_rock`, `item_iron_ore`, `item_gold_ore`, `item_crystal` | §5 | code-drawn chunks | ground piles and stockpiles |
| 10 | `npc_<role>_build` ×4 | §4 "Later" (6 frames, hammering) | the dig sheet (pickaxe) | building jobs (walls, ladders, buildings) |
| 11 | `npc_<role>_sleep` ×4, `npc_<role>_fall` ×4 | §4 "Later" | a still walk frame | beds (M3) and falling; rare on screen |
| 12 | toolbar icons ×11: `icon_select`, `icon_dig`, `icon_build`, `icon_ladder`, `icon_build_menu`, `icon_deconstruct`, `icon_stockpile`, `icon_clear_stockpile`, `icon_priority`, `icon_cancel`, `icon_rooms` | §7 | text-only buttons | readability of the toolbar |

## Notes from batch 1 (already applied to PROMPTS_V1)
- **Terrain:** dirt and rock were not seamless. The import tool repairs this, but large stones get cut at the
  seams. The prompt now asks for a perfectly repeating tile, larger simple shapes readable at 64 px, even
  brightness and no vignette.
- **Characters:** stray specks and dust, dark or red fringes, the pickaxe crossing into the next frame, and a
  different character size per sheet were all fixed by the import tool. The prompt now asks for no loose
  particles, tools fully inside their cell, the same head size in every frame, and clean edges.
- Batch 1 sheets were 1:2 cells (for example 2172 × 724 for 6 frames). That is perfect; keep it.
- Always attach `ref_<role>.png` as the reference and reuse the seed. Batch 1 roles look consistent.
