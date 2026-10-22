# MISSING_V1.md — art still needed (after batch 2)

> **สำหรับเจ้าของโปรเจกต์:** ชุดที่ 2 (53 ภาพ) นำเข้าเกมแล้ว ตอนนี้ครบเกือบทั้งหมดของ Art V1 เหลือเพียงไอคอน 3 อันด้านล่าง
> ขั้นต่อไปคือชุดชิ้นส่วนตัวละครสำหรับระบบโครงกระดูก (ดู `docs/art/PROMPTS_V2_RIG.md`)

Imported so far (`tools/art_import.gd`):
- **Batch 1 (2026-10-21):**
  - terrain: dirt, rock, iron_ore, gold_ore, crystal
  - ladder
  - walk and dig for all 4 roles
  - miner carry and climb
- **Batch 2 (2026-10-21):**
  - backwall_dug: from `background_wall_v1..v4`, a name the importer now also accepts
  - sky_surface: from `sky_surface_v2`
  - terrain: bedrock, concrete
  - items ×5
  - buildings: door, crate, bed, table
  - for all 4 roles: idle (4 frames), build (6), sleep (2, in a 192 px wide cell), fall (2)
  - carry and climb for technician, scientist, cook
  - toolbar icons ×8

| # | Send as | Prompt section | Until then |
|---|---|---|---|
| 1 | `icon_build_menu`, `icon_deconstruct`, `icon_rooms` | PROMPTS_V1 §7 | text-only buttons |
| 2 | `building_farm_plot`, `building_kitchen` (M4a, 2×1 tiles each) | PROMPTS_V1 §6 table (rows added) | code-drawn soil bed / stove |
| 3 | `item_mushroom`, `item_meal`, `item_ration` (M4a food) | PROMPTS_V1 §5 table (rows added) | code-drawn cap / bowl / tin |
| 4 | rig parts sheets (miner first) | PROMPTS_V2_RIG §1 | pilot rig cut from the idle sheet |

## Notes from batch 2
- Some idle sheets are drawn bigger than the walk sheets. The importer rescales them by head width, but miner
  idle still clips about 105 px (mostly the helmet lamp glow), and technician build clips 61 px (the raised
  hammer). Neither is visible at normal zoom.
- The sleep sheets are curled-up poses in about a 1:1 frame, so they use a 192 × 192 cell (ASSET_SPEC §6).
