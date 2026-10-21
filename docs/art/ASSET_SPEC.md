# ASSET_SPEC.md: Art V1 asset specification

Status: **DRAFT V1 for owner approval** (D-020, M3 plan §3). Derived from the approved concept sheets
`docs/visual/concept/01..04` (D-002, style "A+C Cozy Realistic × Cute & Colorful"). Scale values follow D-003
(`data/config/scale_config.tres`). The game loads every file below automatically when it exists
(`src/presentation/art/art_library.gd`). When a file is missing, the game draws the procedural path-B art instead,
so files can be delivered one at a time.

## 1. Global rules
| Rule | Value |
|---|---|
| View | Side view (2D cross-section), orthographic, no perspective, no isometric |
| Base unit | 1 tile = **64 × 64 px** at zoom 1 (camera zoom range 0.25–2.0) |
| Format | **PNG, RGBA 8-bit, transparent background** (except terrain tiles, which are opaque) |
| Colour space | sRGB. Do not put text, watermarks, logos, frames, drop shadows outside the cell, or grid lines in the image |
| Lighting | Warm key light from the **top-left**, soft. A dark outline (`#1e1712`, 2–3 px at 1×) on characters, items and buildings |
| Pivot | Characters and buildings use the **bottom-centre** of the cell as the pivot. That point stands on the floor line |
| Sheets | **Fixed cell size, one row, no padding, no gaps, no margins.** Frame *i* is at x = i × cell_w, y = 0 |
| Facing | Characters face **right**. The game mirrors them for left |
| Delivery size | Exactly the sizes below. Larger square deliveries (for example 128 px tiles) are accepted and down-scaled by the loader, but the aspect ratio must match |

## 2. Folder layout and names (`res://assets/production/`)
```
assets/incoming/               # raw owner images (Godot-ignored); see PROMPTS_V1.md §8
assets/production/
  terrain/     terrain_<material>.png        # 256x64 strip = 4 variants of 64x64
  structures/  ladder.png                    # 64x64, transparent
  backgrounds/ backwall_dug.png              # 256x64 strip, opaque (wiring pending, see §5.3)
               sky_surface.png               # 1920x540, opaque (wiring pending)
  characters/  npc_<role>_<anim>.png         # one row of 128x192 cells
  items/       item_<material>.png           # 64x64, transparent
  buildings/   building_<key>.png            # size per §7, transparent
  ui/          icon_<tool>.png               # 64x64, transparent
```
Names are snake_case ASCII. `<material>` matches the TileDef key: `dirt`, `rock`, `iron_ore`, `gold_ore`,
`crystal`, `bedrock`, `concrete`. `<role>`: `miner`, `technician`, `scientist`, `cook`.

## 3. Palette (sampled from the concepts)
| Name | Hex | Use |
|---|---|---|
| Helmet yellow | `#fcb639` | miner helmet, highlights, UI accent |
| Safety orange | `#d76729` | vests, technician helmet |
| Leather brown | `#603b29` | belts, boots, wood shadows |
| Dust beige | `#b8a395` | reflective bands, cloth |
| Slate | `#3b404c` | trousers, metal |
| Charcoal | `#302929` | dark straps, deep shadow |
| Night navy | `#1c232b` | UI panels, night sky |
| Steel blue | `#4b6288` | iron, technician outfit |
| Sky blue | `#63add8` | glass, iron highlights |
| Outline | `#1e1712` | all outlines |
| Dirt | `#7a5638` / dark `#5a3f2a` / light `#977254` | dirt tile |
| Rock | `#67615b` / dark `#433e3a` / light `#91887d` | rock tile |
| Gold | `#e5a82e` / dark `#7a4f12` / light `#fff0a0` | gold ore |
| Crystal | `#a24fd6` / dark `#4a2260` / light `#efc0ff` | crystal ore |
| Bedrock | `#2e292b` / light `#4a4245` | bedrock |
| Concrete | `#8a8e93` / dark `#62666b` / light `#adb1b5` | concrete wall |
| Wood | `#8a5a2b` / dark `#4a2e16` / light `#b9824a` | ladder, crate |
| Skin tones | `#f6d2b0 #ecc097 #d9a477 #b97e52 #8d5a37` | diversity (03_npc_roster) |
| Lamp light | `#fff3b0` | helmet lamp, room lights |

The code copy of this palette is `src/presentation/art/art_palette.gd`.

## 4. Terrain tiles
- **Cell 64 × 64, opaque, seamless.** Each file is a **strip of 4 variants**: 256 × 64 px (variant 0 at x = 0).
  The game picks a variant per cell from a hash of the cell position (shader), so the variants must be
  interchangeable: same base colour and brightness, different detail placement.
- Tileable: the left/right and top/bottom edges of every variant must continue into any other variant of the same
  material. Keep large features away from the outer 4 px. A soft darker rim (about 2 px, 15–35 % darker) is allowed
  and matches the concept's "chunky block" look.
- Ores (`iron_ore`, `gold_ore`, `crystal`) use a rock base with clearly readable deposits: 3–5 clusters, a bright
  highlight, and 1–3 small sparkle stars. They must read at zoom 0.5 (32 px on screen).

| File | Look (from 01/02 "Environment tiles") |
|---|---|
| `terrain_dirt.png` | warm brown soil, small pebbles, fine roots |
| `terrain_rock.png` | grey-brown cobbles with dark cracks |
| `terrain_iron_ore.png` | dark rock + blue faceted crystals (steel blue / sky blue) |
| `terrain_gold_ore.png` | brown rock + gold nuggets with yellow-white glints |
| `terrain_crystal.png` | dark purple rock + glowing violet shards |
| `terrain_bedrock.png` | near-black dense stone, faint cracks, no detail that suggests it can be dug |
| `terrain_concrete.png` | grey poured-concrete panel, darker frame, horizontal seam, 4 rivets |

**Smooth terrain (D-027).** The game now renders terrain with `TerrainRenderer`, a per-chunk shader:
- Materials are world-space continuous textures from `terrain_hd/terrain_<material>.png` (512 × 512,
  seamless, made by the importer from variant 1). Natural materials repeat every 4 tiles; concrete repeats every
  tile, so it reads as panels.
- Edges are rounded and organic, computed from neighbours, with a dark outline and a light top highlight.
  Where two materials meet, the border is noisy with a dark seam.
- Dug space gets a cavity shadow, and everything darkens slightly with depth.
- The 64 px strips below remain the fallback (`WorldView.smooth_terrain = false`).

The 64 px strips' own edge transitions between materials and to open air are **not** in V1 (would need autotiling in WorldView, which the
UI Agent and Lead own). Proposed for V2: a 47-tile blob set per material.

## 5. Structures and backgrounds
### 5.1 Ladder: `structures/ladder.png`
64 × 64, transparent. Two vertical wooden rails (inset about 10 px from each side) plus 3 rungs spaced evenly
(centres at y = 11, 32, 53). The top and bottom must join seamlessly when stacked. Metal bolts at the joints.

### 5.2 Background wall (dug area): `backgrounds/backwall_dug.png`
256 × 64 strip of 4 opaque 64 × 64 variants. Dark, low-contrast rock face (`#2a2220`–`#3a2f2a`), so terrain and
characters stay readable on top of it.

### 5.3 Surface sky: `backgrounds/sky_surface.png`
1920 × 540, opaque. Dusk/night sky like the concept (purple-orange horizon, dark mountains, a ruined city
silhouette). The horizon is at the bottom 25 %.

> Wiring note: WorldView (`world_view.gd`, UI Agent / Lead) currently fills dug areas and sky with flat colours.
> Using these two files needs a small change there. The files can be delivered before that change.

## 6. Characters (NPCs)
- **Cell 128 × 192 px** (2 × 3 tiles; widened from 96 in batch 1 so pickaxe swings fit). The character is about **160 px tall** (2.5 tiles), centred horizontally, feet on the
  bottom edge (pivot = bottom-centre). The head is about 40 % of the height (chibi). Top 30 px of headroom is for
  hats and helmets.
- One sheet per role per animation: `characters/npc_<role>_<anim>.png`. Width = frames × 128. Height = 192.
- Outfits are **baked into each role sheet** (no runtime layering in V1), because an image AI cannot keep separate
  layers aligned. Skin and hair diversity is out of scope for V1 sheets. Use the default look from the reference.
- Right-facing, 3/4 side view like the "Animation Examples" strip on `04_miner_sheet.png`.
- The carried item is drawn by the game. In `carry` frames, both hands are held in front of the chest
  (about x = +17, y = −64 relative to the feet pivot) with empty hands.

| Anim | Frames | FPS | Loop | Notes |
|---|---|---|---|---|
| `idle` | 4 | 4 | yes | breathing, one blink |
| `walk` | 6 | 10 | yes | 1 cycle ≈ 1 tile travelled |
| `climb` | 4 | 8 | yes | back or 3/4 view on a ladder, arms alternate |
| `dig` | 6 | 8 | yes | pickaxe swing, impact on the last frame |
| `carry` | 6 | 10 | yes | walk with arms forward (item added by the game) |
| `build` | 6 | 8 | yes | hammering at chest height |
| `sleep` | 2 | 2 | yes | lying on the side (for beds, M3) |
| `fall` | 2 | 8 | yes | arms up, surprised face |

Roles and outfits (from `03_npc_roster.png`):
| Role | Outfit |
|---|---|
| `miner` | yellow hard hat with headlamp, olive-brown work shirt, orange hi-vis vest straps with beige reflective bands, cargo trousers, brown boots, tool belt |
| `technician` | orange hard hat with blue goggles on the band, steel-blue coverall, tool pouch |
| `scientist` | no hat, neat dark hair, round glasses, long white lab coat over a coloured shirt, slate trousers |
| `cook` | tall white chef hat, white double-breasted jacket, coloured neckerchief, dark trousers |

The procedural fallback uses the same roles, chosen per NPC id (cosmetic only, not a gameplay role).

## 7. Items and buildings
| File | Size | Notes |
|---|---|---|
| `items/item_dirt.png`, `item_rock.png`, `item_iron_ore.png`, `item_gold_ore.png`, `item_crystal.png` | 64 × 64 | one small pile/chunk centred, touching the bottom edge, about 40 × 32 px of content. Drawn at 0.3 tile in the world and reused as UI icons |
| `buildings/building_door.png` | 64 × 192 (1 × 3 tiles) | metal bunker door, closed, frame included |
| `buildings/building_crate.png` | 64 × 64 | wooden storage crate (see 04 scale comparison) |
| `buildings/building_bed.png` | 128 × 64 (2 × 1) | simple bunk/cot, blanket, pillow on the left |
| `buildings/building_table.png` | 128 × 64 (2 × 1) | sturdy work/dining table, side view |

Buildings are transparent, bottom-aligned (the floor line is the bottom edge), lit from the top-left, outlined.
Wiring of buildings and icons into the game happens with the M3 building work (UI Agent). The loader names already exist.

## 8. UI icons (toolbar, 11)
`ui/icon_<tool>.png`, 64 × 64, transparent, white/cream glyph (`#f2e6d0`) with a dark outline, a single readable
silhouette that works at 24 px. Icons, in toolbar order (names used by `ui/toolbar.gd`): `select`, `dig`,
`build` (build wall), `ladder`, `build_menu` (opens the building menu), `deconstruct`, `stockpile`,
`clear_stockpile`, `priority`, `cancel`, and `rooms` (rooms overlay toggle). Style reference: the left command bar on
`01`/`02`.

## 9. Godot import settings
All files under `assets/production/` are imported as **Image** resources (`importer="image"`), not as textures.
`ArtLibrary` turns them into `ImageTexture`s at runtime. Reasons: terrain and ladder tiles are composited into the
TileSet atlas on the CPU, and reading pixels back from a GPU texture (`Texture2D.get_image()`) is unreliable in
the Web build. Image import keeps the exact PNG pixels (lossless) with no mipmaps. `tools/art_import.gd` writes the
`.import` stub for every file it produces. Filter: project default (linear); pixel-exact nearest filtering is not
used because the art is painterly (OQ-08 stays open).

## 9b. Import pipeline (`tools/art_import.gd`)
Owner images go to `assets/incoming/` (git-ignored). Then run:
`godot --headless --path . -s res://tools/art_import.gd -- --src <incoming dir>`. It is safe to re-run.
- **NPC sheets:**
  - **Slicing:** the frame count is the number of 1:2 cells in the sheet. Every opaque blob goes to the frame
    whose column contains its centroid, so tools that overhang a neighbour stay with their own figure. Dust under
    0.3 % of the largest blob is dropped.
  - **Scale:** each role's `walk` sheet sets the scale: head top to feet = 150 px (cook +22 px for the hat).
    The role's other sheets match the walk sheet's head width, so crouching or stretched poses keep the same
    character size.
  - **Placement:** feet go on the bottom edge and the body (median x of the torso band) on the cell centre.
  - **Cleanup:** faint alpha below 24 is dropped, specks smaller than 1 % of the figure are removed, and
    semi-transparent edge pixels take the colour of their opaque neighbours (removes dark and red fringes).
- **Terrain:**
  - Each variant is downsampled to 256 px and made seamless with a minimum-error cut through a 16 % wrap overlap
    (no cross-fade ghosting).
  - Variants 2–4 then get variant 1's outer 22 % border, again via minimum-error cuts, so any two variants can sit
    next to each other.
  - Lanczos resampling to 64 px, then packed into the 4-variant strip.
- **Ladder:** cropped to exactly 3 rung periods (half a period above the first rung) so stacked tiles keep even
  spacing, then scaled to 64 × 64.

**Fallbacks in game:** a missing animation uses the role's sheet chain `ArtLibrary.NPC_FALLBACK`:
- idle, sleep and fall: a still standing frame of `walk`
- carry and climb: `walk` (the game draws the carried chunk)
- dig and build: each other, then `walk`

A role without any sheet uses the procedural rig. A missing terrain material or ladder uses the procedural tile.

## 10. Acceptance checklist (per file)
1. Exact size; for sheets, width is a multiple of the cell width.
2. Transparent background where required (no white or checkerboard pixels).
3. Character feet touch the bottom edge in every frame; the head stays at the same height across `idle` frames.
4. No text, logo, watermark, or grid lines.
5. Colours stay close to §3. Outline present.
6. The game shows it after re-import (`tools/run_tests.ps1` passes; the screenshot is checked in a Web build).
