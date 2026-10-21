# PROMPTS_V1.md: Image-generation prompt pack (Art V1)

> **สำหรับเจ้าของโปรเจกต์:** ไฟล์นี้คือชุด prompt ภาษาอังกฤษ (AI วาดภาพเข้าใจภาษาอังกฤษดีที่สุด) ให้คัดลอกไปวางในเครื่องมือ AI
> ที่ใช้ทำภาพคอนเซ็ปต์ทีละอัน ขนาดและกฎทั้งหมดมาจาก `docs/art/ASSET_SPEC.md` ได้ภาพแล้วให้วางตามหัวข้อ
> "วิธีส่งภาพกลับ" ด้านล่าง Asset Agent จะตัด ทำความสะอาด และนำเข้าเกมให้เอง เกมจะใช้ภาพใหม่ทันทีที่มีไฟล์
> ถ้าภาพไหนยังไม่มี เกมจะใช้ภาพที่วาดด้วยโค้ดแทน ทยอยส่งทีละชุดได้
> (ยังไม่มีภาพ AI ใดในโปรเจกต์ตอนนี้ ทุกอย่างในเกมยังเป็นภาพจากโค้ด)

## 0. How to use (read once)
- **Run order:** see §9 "Run these first".
- **Size:** most image AIs cannot output exact pixel sizes. Generate at the **same aspect ratio** and a **larger
  size** (the prompt says which), and the Asset Agent scales it down. Never crop off feet or hats.
- **One asset (or one sheet) per image.** Do not ask for several sheets in one picture.
- **Transparent background:** if your tool cannot output transparency, ask for a **flat pure green background
  `#00FF00`** (chroma key) instead. The Asset Agent removes it. Never use a checkerboard pattern.
- **Reference image:** attach the matching concept sheet from `docs/visual/concept/` (or your accepted master
  character from §1) as the image reference / style reference every time. Use the same seed, if your tool has
  one, for every image of the same character.
- If a result has text, a watermark, a frame, or extra characters, regenerate. Do not fix it by hand.

---

## 1. Consistency kit

### 1.1 Style block (pasted inside every prompt below as `[STYLE]`)
```text
[STYLE] = 2D game art for a side-view underground colony simulation, style "cozy realistic x cute and colorful":
cute chibi characters with big heads (head about 40% of body height), large expressive brown eyes, small blush,
clean dark brown outlines 2-3 px, soft cel shading with one warm highlight, warm key light from the top-left,
slightly desaturated earthy palette with saturated accents (helmet yellow #fcb639, safety orange #d76729,
leather brown #603b29, steel blue #4b6288, sky blue #63add8, charcoal #302929), high detail but readable at small
size, painterly hand-drawn texture, consistent with the reference sheet
```

### 1.2 Negative block (`[NEG]`, use as the negative prompt, or append "Avoid: ..." if the tool has no negative field)
```text
[NEG] = text, letters, numbers, labels, watermark, signature, logo, UI, frame, border, grid lines, checkerboard
background, gradient background, scenery behind the subject, perspective, isometric view, top-down view, 3D render,
photorealistic, blurry, motion blur, cropped feet, cropped head, extra limbs, extra fingers, duplicated character,
inconsistent outfit between frames, different character size between frames, drop shadow outside the cell
```

### 1.3 Master character reference (run this FIRST, keep the best result)
> **หมายเหตุ:** ภาพนี้คือ "ต้นแบบ" ของตัวละครช่างขุด เลือกภาพที่ชอบที่สุดแล้วใช้แนบเป็น reference ในทุก prompt ตัวละคร
> ถ้าเครื่องมือมีค่า seed ให้จดไว้และใช้ seed เดิมทุกครั้ง ช่วยให้หน้าตาและชุดเหมือนกันทุกท่า
```text
Character reference sheet of ONE chibi miner colonist, [STYLE].
Young adult with messy dark brown hair, yellow hard hat with a round headlamp on the front, olive-brown work shirt,
orange hi-vis vest straps with beige reflective bands, brown tool belt with a brass buckle, khaki cargo trousers,
dark brown boots. Friendly determined face.
Show the same character 3 times side by side, equal size, full body, standing on the same baseline:
front view, right-facing 3/4 side view, back view. Each figure about 2.5 head-and-body units tall,
chibi proportions exactly like the reference image.
Flat pure white background, no ground, no shadow.
Aspect ratio 3:2, at least 1536x1024.
Negative: [NEG]
```
Do the same for the other three roles by replacing the outfit sentence with the role text in §4.

### 1.4 Tips for tileable terrain
- Ask for **one tile per image**, square, at 1024 × 1024, "seamless tileable texture". Generate 4 versions
  (variants) with the same prompt and different seeds.
- If your tool has a "tiling / seamless" switch, turn it on.
- Ask for "no large objects touching the edges" so the seams stay invisible.
- Check: place two copies side by side and on top of each other in any image viewer. If you see a hard seam,
  regenerate or tell the Asset Agent (seams can be repaired by offset-and-blend).

---

## 2. Terrain tiles (7 materials × 4 variants)
> **หมายเหตุ:** บล็อกพื้นดินแต่ละชนิด ทำ 4 แบบ (สุ่ม seed ต่างกัน) ต่อชนิด ใช้ prompt เดียวกัน เปลี่ยนแค่ seed
> เกมจะสุ่มสลับ 4 แบบให้พื้นไม่ดูซ้ำ ไฟล์ต้องเป็นสี่เหลี่ยมจัตุรัสและต่อกันได้ไร้รอยต่อ

Template (replace `<MATERIAL TEXT>`):
```text
Single square game terrain tile, seamless tileable texture that repeats perfectly left-right and top-bottom,
side-view cross-section of underground ground, [STYLE], <MATERIAL TEXT>, fills the whole square edge to edge,
larger simple shapes that stay readable when shrunk to 64x64 pixels (about 6-12 main shapes, not hundreds of tiny
ones), even brightness across the whole tile, no rim or vignette, no large objects touching the edges,
lighting from the top-left, opaque, no background.
Square 1:1, 1024x1024.
Negative: [NEG], objects, characters, plants on top, vignette, darker corners, visible seams, noisy micro detail
```

| File you send | `<MATERIAL TEXT>` |
|---|---|
| `terrain_dirt_v1..v4` | warm brown packed soil (#7a5638), small scattered pebbles, a few thin dry roots, fine grain |
| `terrain_rock_v1..v4` | grey-brown cobblestone rock (#67615b) made of 5-7 rounded stones with dark cracks between them |
| `terrain_iron_ore_v1..v4` | dark grey rock with 3-4 clusters of faceted steel-blue iron crystals (#4b6288) with sky-blue highlights (#8fd0f2) and one tiny white sparkle |
| `terrain_gold_ore_v1..v4` | dark brown rock with 4-5 shiny gold nuggets (#e5a82e) with pale yellow glints and small sparkles |
| `terrain_crystal_v1..v4` | dark purple-black rock with 2-3 clusters of glowing violet crystal shards (#a24fd6), soft magical glow |
| `terrain_bedrock_v1..v4` | almost black dense stone (#2e292b), very low detail, faint thin cracks, looks unbreakable |
| `terrain_concrete_v1..v4` | grey poured concrete wall panel (#8a8e93), darker frame around the square, one horizontal seam in the middle, a small rivet in each corner, light stains |

### 2.1 Background wall (dug area), 4 variants
> **หมายเหตุ:** ผนังหินด้านหลังของโพรงที่ขุดแล้ว ต้องมืดและเรียบ เพื่อให้ตัวละครเด่น
```text
Single square seamless tileable texture of a dark excavated rock wall seen from the front, background layer of an
underground cave, [STYLE], very dark warm brown-grey (#2a2220 to #3a2f2a), low contrast, soft pick marks,
no bright details, no objects. Square 1:1, 1024x1024.
Negative: [NEG], high contrast, bright spots
```

### 2.2 Ladder
> **หมายเหตุ:** บันไดไม้ ตั้งซ้อนกันหลายช่องได้ ขอบบนและล่างต้องต่อกันพอดี
```text
Single square game tile of a wooden ladder segment, front view, [STYLE], two vertical wooden rails near the left and
right sides, exactly 3 evenly spaced horizontal rungs, small metal bolts at the joints, the rails run off the top and
bottom edges so stacked tiles join seamlessly, transparent background (or flat pure green #00FF00).
Square 1:1, 1024x1024.
Negative: [NEG], wall behind the ladder, shadow
```

---

## 3. Sky / surface background
> **หมายเหตุ:** ฉากท้องฟ้าบนพื้นผิวตอนค่ำ แบบในภาพคอนเซ็ปต์ (ภูเขา เมืองร้าง ท้องฟ้าม่วงส้ม)
```text
Wide 2D side-view game background of the surface at dusk, [STYLE], dark purple to orange horizon sky, distant dark
blue mountains, silhouette of a ruined city skyline, a few stars, no ground in the bottom 10%, no characters,
no buildings in the foreground, parallax-friendly flat layers.
Aspect ratio 32:9 (or 16:9), at least 1920x540.
Negative: [NEG], zombies, people, vehicles, sun
```

---

## 4. Characters (4 roles × 5 animations for V1)
> **หมายเหตุ:** ตัวละคร 4 อาชีพ แต่ละอาชีพมี 5 ท่าก่อน (เดิน ปีน ขุด แบกของ ยืน) ทำทีละท่าต่อภาพ
> แนบภาพต้นแบบจาก §1.3 ของอาชีพนั้นเป็น reference ทุกครั้ง ตัวละครต้องขนาดเท่ากันทุกช่อง เท้าแตะขอบล่าง หันขวา
> ถ้า AI วาดจำนวนช่องไม่ตรง ไม่เป็นไร ส่งมาได้ Asset Agent จะจัดใหม่ แต่ห้ามตัดเท้าหรือหมวก

Role text (`<ROLE TEXT>`):
| Role | `<ROLE TEXT>` |
|---|---|
| miner | chibi miner with yellow hard hat and round headlamp, olive-brown shirt, orange hi-vis vest straps with beige reflective bands, tool belt, khaki cargo trousers, brown boots |
| technician | chibi technician with orange hard hat with blue goggles on the band, steel-blue coverall with a chest pocket, tool pouch, brown boots |
| scientist | chibi scientist with neat black hair, round glasses, long white lab coat over a purple shirt, slate trousers, dark shoes |
| cook | chibi cook with tall white chef hat, white double-breasted chef jacket, small colored neckerchief, dark trousers, dark shoes |

Sheet template (replace `<ROLE TEXT>`, `<N>`, `<ACTION TEXT>`):
```text
2D game sprite sheet, ONE row of <N> animation frames of the SAME character, [STYLE], <ROLE TEXT>,
right-facing 3/4 side view, orthographic.
Frames are equal-width cells of exactly the same size placed edge to edge with no gaps; each cell is twice as tall
as it is wide (1:2); the character is centred in each cell, the same size in every frame, about 83% of the cell
height, feet touching the bottom edge of the cell, empty space above the head for the hat.
Animation: <ACTION TEXT>. Smooth loop, consistent outfit and colours in every frame. The character is exactly
the same size as in the reference sheet and the head is the same size and height in every frame. Tools stay fully
inside their own cell with a clear margin. No loose particles, dust, sparks or debris floating around the
character. Clean edges, no coloured halo.
Transparent background (or flat pure green #00FF00). Whole image aspect ratio <N>:2, at least <N*256>x512.
Negative: [NEG], background scenery, floor line, numbers under frames, dust particles, flying debris, specks,
tool crossing into the next frame, red or dark fringe around the outline
```

| Send as | `<N>` | `<ACTION TEXT>` |
|---|---|---|
| `npc_<role>_walk` | 6 | walk cycle to the right, arms swinging opposite to the legs, slight up-down body bob |
| `npc_<role>_climb` | 4 | climbing a ladder seen from behind at a slight angle, hands alternately reaching up, knees alternately raised (do not draw the ladder) |
| `npc_<role>_dig` | 6 | swinging a pickaxe: raise it over the head behind, swing forward and down, strike the ground in front at foot level on the last frame with small dust bits |
| `npc_<role>_carry` | 6 | walk cycle to the right with both arms held forward at chest height as if carrying a box, hands empty (the game adds the item) |
| `npc_<role>_idle` | 4 | standing relaxed, gentle breathing, one frame with the eyes closed (blink) |

Later (M3, not needed yet): `build` (6, hammering at chest height), `sleep` (2, lying on the side, eyes closed),
`fall` (2, arms up, surprised).

---

## 5. Item icons (5)
> **หมายเหตุ:** กองแร่/หินเล็กๆ ที่วางบนพื้นและใช้เป็นไอคอน พื้นหลังโปร่งใส
```text
Single 2D game item icon, [STYLE], <ITEM TEXT>, centred, resting on the bottom edge, front side view with slight
top light, thick dark outline, transparent background (or flat pure green #00FF00), no shadow on the ground.
Square 1:1, 512x512, the item fills about 65% of the width.
Negative: [NEG]
```
| Send as | `<ITEM TEXT>` |
|---|---|
| `item_dirt` | small heap of loose brown soil clumps |
| `item_rock` | small pile of 3 grey-brown rocks |
| `item_iron_ore` | chunk of grey rock with blue faceted iron crystals |
| `item_gold_ore` | chunk of brown rock with shiny gold nuggets and a sparkle |
| `item_crystal` | cluster of glowing violet crystal shards on a dark rock base |

---

## 6. Buildings (4)
> **หมายเหตุ:** สิ่งก่อสร้างสำหรับ M3 ประตู กล่องเก็บของ เตียง โต๊ะ ขนาดตามช่องตาราง (ประตูสูง 3 ช่อง เตียงกับโต๊ะกว้าง 2 ช่อง)
```text
Single 2D game building sprite, side view (cross-section game), [STYLE], <BUILDING TEXT>, standing on the bottom
edge (the floor line is the bottom of the image), lit from the top-left, thick dark outline,
transparent background (or flat pure green #00FF00). Aspect ratio <RATIO>, at least <SIZE>.
Negative: [NEG], room, wall behind, floor, characters
```
| Send as | `<BUILDING TEXT>` | `<RATIO>` | `<SIZE>` |
|---|---|---|---|
| `building_door` | heavy metal bunker door, closed, riveted steel frame, small warning stripe at the bottom, one tile wide and three tiles tall | 1:3 | 512x1536 |
| `building_crate` | sturdy wooden storage crate with metal corner brackets and an X brace | 1:1 | 1024x1024 |
| `building_bed` | simple bunker cot bed with a grey-green blanket and a pillow on the left, metal legs | 2:1 | 1536x768 |
| `building_table` | sturdy wooden work table with metal legs, a few small tools on top | 2:1 | 1536x768 |
| `building_farm_plot` | raised wooden planter bed with dark soil and rows of small green crop sprouts, a tiny grow lamp above | 2:1 | 1536x768 |
| `building_kitchen` | compact bunker kitchen: steel stove with two glowing burners, a steaming pot, a small shelf with jars | 2:1 | 1536x768 |

---

## 7. Toolbar icons (11)
> **หมายเหตุ:** ไอคอนปุ่มเครื่องมือ 11 อัน (เพิ่ม build_menu, deconstruct, rooms สำหรับ M3) ทำทีละอัน ใช้ prompt เดียวกัน เปลี่ยนรูปสัญลักษณ์ ต้องอ่านออกเมื่อย่อเหลือ 24 พิกเซล
```text
Single game UI icon, flat simple glyph of <ICON TEXT>, cream color (#f2e6d0) with a thick dark outline (#1e1712),
very bold readable silhouette, centred, no background shape, transparent background (or flat pure green #00FF00).
Square 1:1, 512x512. Style matches the command bar icons of the reference image.
Negative: [NEG], gradient, 3D, multiple objects, tiny details
```
| Send as | `<ICON TEXT>` |
|---|---|
| `icon_select` | a mouse arrow cursor |
| `icon_dig` | a pickaxe |
| `icon_build` | a brick wall with a small trowel |
| `icon_ladder` | a short ladder |
| `icon_stockpile` | three stacked boxes |
| `icon_clear_stockpile` | three stacked boxes with a diagonal cross line |
| `icon_priority` | an exclamation mark inside a circle |
| `icon_cancel` | a bold X inside a circle |
| `icon_build_menu` | a small house outline with a plus sign |
| `icon_deconstruct` | a crowbar crossing a broken brick |
| `icon_rooms` | a floor plan of two rooms side by side with a door gap |

Toolbar order (11 buttons): select, dig, build (wall), ladder, build_menu, deconstruct, stockpile, clear_stockpile,
priority, cancel, rooms.

---

## 8. How to hand the images back
> **หมายเหตุ:** วางไฟล์ภาพดิบ (ยังไม่ต้องตัดหรือย่อ) ไว้ในโฟลเดอร์ `assets/incoming/` ตั้งชื่อตามคอลัมน์ "Send as" ในแต่ละตาราง
> ลงท้ายด้วย `_v1`, `_v2`... ถ้ามีหลายแบบ (เช่น `terrain_dirt_v3.png`) แล้วบอก Asset Agent ว่า "ส่งภาพชุด ... แล้ว"
> Asset Agent จะตัดช่อง ลบพื้นหลัง ย่อขนาด แล้ววางไว้ใน `assets/production/...` ตาม ASSET_SPEC และถ่ายภาพหน้าจอเกมให้ตรวจ

- Folder: `assets/incoming/` (Godot ignores it; raw files are safe there).
- Names: the "Send as" value + `.png` (or `.webp`/`.jpg` if that is what the tool gives). Terrain: `_v1`..`_v4`.
  Characters: `npc_miner_walk.png`, `npc_cook_dig.png`, and so on. Also include the master references as
  `ref_<role>.png`.
- Wrong frame counts, green backgrounds and large sizes are fine. Cropped feet or hats, text in the image, or a
  different-looking character between frames are not fine; regenerate those.

---

## 9. Run these first (smallest set that changes the most on screen)
> **อัปเดต 2026-10-21:** ชุดแรก (batch 1) ได้รับและนำเข้าเกมแล้ว รายการที่ยังขาดและลำดับที่ควรทำต่อ อยู่ใน
> `docs/art/MISSING_V1.md`
> **หมายเหตุ:** ถ้ามีเวลาน้อย ให้ทำ 6 ข้อนี้ก่อน เห็นผลในเกมมากที่สุด
1. **§1.3 master reference: miner** (pick the best, note the seed).
2. **§2 `terrain_dirt` × 4** and **`terrain_rock` × 4** (most of the visible world).
3. **§4 `npc_miner_walk`** and **`npc_miner_dig`** (what you see NPCs do most).
4. **§2 ores: `terrain_iron_ore`, `terrain_gold_ore`, `terrain_crystal`** × 4 each.
5. **§2.2 ladder**, then **§4 `npc_miner_climb`** and **`npc_miner_carry`**.
6. **§1.3 references for technician, scientist, cook**, then their walk/dig sheets.
