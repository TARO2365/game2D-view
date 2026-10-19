# ASSET_CONVENTIONS.md — DRAFT (pending Visual Design Phase)

Values here are WORKING ASSUMPTIONS (DECISIONS D-003). Final values come from the approved asset specification.

| Item | Assumption |
|---|---|
| Tile | 64 × 64 px |
| NPC sprite | ~160 px tall (≈ 2.5 tiles), pivot bottom-center at feet |
| Surface zombie | ≈ 3 tiles tall |
| Agent clearance | small 1 / standard 3 / large 4+ tiles (`scale_config.tres`) |
| Texture filter | TBD (OQ-08) |
| Render layers (proposal) | background → terrain → structures/back-walls → fixtures → agents → FX → fog of war → overlays → UI (CanvasLayer) |
| Placeholders | Only in `assets/placeholder/`; flat colors or labelled boxes; never ship |
| Production art | `assets/production/<category>/`, snake_case names, spritesheets per animation set |
| Reference | `docs/visual/concept/*.png` (approved direction D-002) |
