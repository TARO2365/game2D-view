# PROMPTS_V2_RIG.md: Character parts sheets for the 2D cut-out rig (D-027)

> **สำหรับเจ้าของโปรเจกต์:** ระบบใหม่ไม่ใช้ภาพทีละเฟรมแล้ว แต่ใช้ "ชิ้นส่วนตัวละคร" (หัว ลำตัว แขน ขา) แยกเป็นชิ้น ๆ
> แล้วเกมขยับข้อต่อเองแบบลื่นไหล 60 FPS เหมือนหุ่นกระดาษตัดต่อ ขอเพียงภาพเดียวต่อตัวละคร
> **เริ่มจาก §1 (ช่างขุด) ก่อน** แนบ `ref_miner.png` เป็นภาพอ้างอิงทุกครั้ง
> ส่งกลับที่ `assets/incoming/` ด้วยชื่อ `rig_miner_parts.png` แล้วสั่ง Asset Agent ให้นำเข้า (`tools/art_import.gd`)
> ระหว่างนี้เกมใช้ชิ้นส่วนที่ตัดอัตโนมัติจากภาพท่ายืนเดิม (คุณภาพทดลอง)

## How the rig uses the sheet (read once)
- The importer finds every separate part, groups them into **rows**, reads each row left to right, and gives each
  part its name from the fixed layout below. **The order and the number of parts per row must match exactly.**
  If they do not match, the importer refuses the sheet and says which row is wrong.
- **Spacing:** leave clear transparent space between parts (at least ~5 % of the image width). No part may touch
  or overlap another. Do not add shadows, text, labels, numbers, guides or a ground line.
- **Joints and overlap:** every limb segment ends in a **rounded, slightly oversized joint cap** at both ends, with
  the clothing continuing about 10–15 % past the joint. When the segments are stacked, these caps hide the seam.
  - The **top** of each arm/leg segment is its pivot: shoulder, elbow, wrist, hip, knee or ankle.
  - The **bottom** of the head (the neck) is the head's pivot.
  - The **bottom** of the torso (the hips) is the torso's pivot.
- **Pose of each part:** a neutral rest pose, side view facing **right**, with arms and legs hanging straight
  down. Every part is drawn at the **same scale** as the others.
- **Size:** generate large, at least 2048 px wide. The importer scales the assembled character to the game size
  (150 px tall).
- Transparent background, or flat pure green `#00FF00` if your tool cannot do transparency.

Fixed layout (rows top to bottom):
| Row | Parts, left to right |
|---|---|
| 1 | head (with hair, without helmet or hat) · helmet/hat · torso (with clothes/vest) · pelvis (hips/belt) |
| 2 | back upper arm · back forearm · back hand · front upper arm · front forearm · front hand |
| 3 | back thigh · back shin · back boot · front thigh · front shin · front boot |
| 4 | prop (tool, e.g. pickaxe) · head again with **eyes closed** (blink) |

"Back" = the far side (the left limb when the character faces right): slightly darker.
"Front" = the near side.

---

## 1. Miner parts sheet: run this FIRST
> **หมายเหตุ:** ภาพชิ้นส่วนช่างขุดภาพเดียว ใช้ทดสอบระบบโครงกระดูก แนบ `ref_miner.png` (และใส่ seed เดิมถ้ามี)
```text
2D game character PARTS SHEET for a cut-out skeletal animation rig, ONE chibi miner colonist, exactly the same
character, style and colours as the attached reference image: big head (about 40% of total height), large brown
eyes, messy dark brown hair, yellow hard hat with a round headlamp, olive-brown work shirt, orange hi-vis vest
straps with beige reflective bands, brown tool belt with brass buckle, khaki cargo trousers with grey knee pads,
dark brown leather gloves, brown boots. Clean dark brown outlines, soft cel shading, warm light from the top-left.
Every body part drawn SEPARATELY with wide transparent space between parts, nothing touching, all parts at the
same scale, side view facing right, neutral rest pose, limbs straight.
Arrange the parts in exactly 4 rows, left to right:
Row 1: the head with hair but WITHOUT the helmet (3/4 view facing right, neck stump at the bottom); the yellow
hard hat with headlamp alone; the torso with shirt and vest from neck to hips (no arms, no head); the pelvis with
belt and buckle (hips only).
Row 2: back upper arm (sleeve), back forearm, back gloved hand, front upper arm (sleeve), front forearm, front gloved
hand. The back side pieces are slightly darker.
Row 3: back thigh, back shin with knee pad, back boot, front thigh, front shin with knee pad, front boot.
The back side pieces are slightly darker.
Row 4: a pickaxe with a wooden handle, alone; the same head again with the eyes CLOSED (blink).
Every limb piece has rounded, slightly oversized joint ends with the clothing extending a little past the joint,
so the pieces overlap and hide seams when assembled. Shoulder, elbow, wrist, hip, knee and ankle ends are round.
Transparent background (or flat pure green #00FF00), no shadows, no ground, no text, no labels, no numbers,
no guide lines. Wide image, at least 2048x1536.
Negative: text, letters, numbers, labels, arrows, guide lines, grid, assembled character, extra limbs, duplicate
parts, overlapping parts, touching parts, perspective, 3D render, blurry, cropped parts, scenery, ground shadow
```

---

## 2. Modular citizens (later): shared body plus swappable looks
> **หมายเหตุ:** สำหรับชาวบ้านทั่วไปหลายแบบ: ใช้ร่างกายพื้นฐานร่วมกัน แล้วสลับหัว ใบหน้า ผม สีผิว ชุด หมวก และอุปกรณ์
> ทำให้มีพลเมืองหน้าตาหลากหลายเหมือนแผ่น "Diversity" ในคอนเซ็ปต์ ทุกแผ่นต้องใช้มาตราส่วนเดียวกับ §2.1

The rig composes a citizen from slots:
- the base body: pelvis, torso, arms and legs in a neutral undershirt and trousers, with a skin tone
- a head (face shape and skin tone)
- hair
- a hat or helmet
- outfit pieces that replace the torso, upper arms and thighs
- a prop

The game picks one option per slot for each NPC, so a few sheets give many distinct citizens. Each sheet below
uses the same rules as §1 (rows, spacing, joint caps, facing right) and the same scale. Generate §2.1 first and
attach it as the reference for §2.2–2.4.

### 2.1 Base body parts sheet
> **หมายเหตุ:** ร่างกายพื้นฐาน (ไม่มีหัว) ใส่เสื้อยืดและกางเกงเรียบ ๆ สีกลาง ๆ
```text
2D game character PARTS SHEET for a cut-out rig, chibi colonist BASE BODY without head, same art style as the
attached reference (clean dark brown outlines, soft cel shading, warm top-left light), plain light grey t-shirt,
plain dark grey trousers, simple dark shoes, medium skin tone on the hands. Separate parts, wide transparent space,
same scale, side view facing right, neutral pose, rounded oversized joint ends that overlap when assembled.
Row 1: (leave the first slot empty: no head) torso from neck to hips without arms; pelvis.
Row 2: back upper arm, back forearm, back hand, front upper arm, front forearm, front hand (back side darker).
Row 3: back thigh, back shin, back shoe, front thigh, front shin, front shoe (back side darker).
Transparent background, no text, no labels, no shadows. Wide image, at least 2048x1536.
Negative: head, face, text, numbers, labels, overlapping parts, perspective, 3D, scenery
```
(Importer note: this sheet has 2 + 6 + 6 parts. It is imported with the body layout, which has no head and no row 4.)

### 2.2 Head and face variants sheet
> **หมายเหตุ:** หัว 8 แบบ (รูปหน้า สีผิว อายุ เพศต่างกัน) ไม่มีผมและหมวก สำหรับสลับกับร่างกายพื้นฐาน
```text
2D game sprite sheet of 8 chibi HEADS for a cut-out rig, same art style and scale as the attached base body,
3/4 view facing right, large expressive brown eyes, small blush, each head bald (no hair, no hat) with a short
neck stump at the bottom, different face shapes, ages and skin tones (very light, light, tan, brown, dark brown),
some with freckles, glasses on one, a beard on one. Arrange in 2 rows of 4 with wide transparent space between
heads. Below them, a third row with the same 8 heads in the same order with EYES CLOSED (blink).
Transparent background, no text, no labels. At least 2048x2048.
Negative: hair, hats, bodies, text, numbers, overlapping, perspective, 3D
```

### 2.3 Hair variants sheet
> **หมายเหตุ:** ทรงผม 10 แบบ วางทับหัวได้ทุกหัว
```text
2D game sprite sheet of 10 chibi HAIR pieces for a cut-out rig, same art style and scale as the attached heads,
each hair piece drawn alone (no head, no face), shaped to sit on top of the bald heads, 3/4 view facing right:
messy short, neat short, ponytail, long straight, curly afro, bun, buzz cut, side part, braids, spiky.
Varied natural colours (black, dark brown, auburn, blonde, grey). Arrange in 2 rows of 5 with wide transparent
space. Transparent background, no text. At least 2048x1024.
Negative: faces, heads, bodies, text, overlapping, perspective, 3D
```

### 2.4 Outfit parts sheet (one role per image)
> **หมายเหตุ:** ชุดของแต่ละอาชีพ (ลำตัว แขนเสื้อ ขากางเกง หมวก อุปกรณ์) ทำ 1 ภาพต่อ 1 อาชีพ เปลี่ยนข้อความในวงเล็บ
```text
2D game OUTFIT PARTS SHEET for a cut-out rig, same art style and scale as the attached base body, outfit of a
(technician: orange hard hat with blue goggles, steel-blue coverall, tool pouch, wrench prop). Separate pieces
with wide transparent space, side view facing right, rounded oversized joint ends:
Row 1: torso outfit piece from neck to hips (no arms); pelvis outfit piece; the hat alone.
Row 2: back upper sleeve, front upper sleeve.
Row 3: back thigh trouser piece, front thigh trouser piece.
Row 4: the prop tool alone.
Transparent background, no text, no labels. At least 2048x1536.
Negative: head, face, hands, text, numbers, overlapping parts, perspective, 3D, scenery
```
Replace the bracket text for the other roles:
- miner: yellow hard hat with headlamp, olive shirt with orange hi-vis vest straps, khaki cargo trousers with knee
  pads, pickaxe prop
- scientist: no hat (leave the hat slot as a small round lab badge), long white lab coat pieces, slate trousers,
  clipboard prop
- cook: tall white chef hat, white double-breasted jacket with red neckerchief, white apron over dark trousers,
  wooden ladle prop
- farmer (M4): straw hat, green overalls, brown shirt sleeves, watering can prop

---

## 3. How to hand the parts back
- Folder `assets/incoming/`:
  - `rig_miner_parts.png` (§1)
  - later, `rig_base_parts.png`, `rig_heads.png`, `rig_hair.png`, `rig_outfit_<role>.png`
- Run (or ask the Asset Agent to run) `tools/art_import.gd`. It writes `assets/production/rig/rig_<role>.png` and
  `.json`, and the miner switches from the pilot cut to your parts automatically.
- If the importer says `NOT IMPORTED - row N: expected X parts, found Y`, regenerate. Usually two parts touched,
  or a tiny stray speck formed an extra part.
