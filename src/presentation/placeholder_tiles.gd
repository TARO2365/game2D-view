class_name PlaceholderTiles
extends RefCounted
## Runtime-generated flat-color tiles. Obviously not final art; replaced when
## the Visual Design asset specification is approved (ASSET_CONVENTIONS.md).

const TERRAIN_SOURCE := 0
const STRUCTURE_SOURCE := 1
const LADDER_COLOR := Color(0.85, 0.6, 0.25)  # PLACEHOLDER
const LADDER_RUNGS := 3


static func build_tileset(registry: TileRegistry, px: int) -> TileSet:
	var count := registry.max_id() + 1
	var img := Image.create(px * count, px, false, Image.FORMAT_RGBA8)
	for d in registry.all_defs():
		if not d.solid:
			continue
		var ox := d.id * px
		var base := d.placeholder_color
		img.fill_rect(Rect2i(ox, 0, px, px), base.darkened(0.35))
		img.fill_rect(Rect2i(ox + 2, 2, px - 4, px - 4), base)
		var speck := base.lightened(0.35) if d.placeholder_speckle_light else base.darkened(0.15)
		var rng := RandomNumberGenerator.new()
		rng.seed = d.id * 7919 + 1
		for i in 10:
			var s := rng.randi_range(3, 7)
			img.fill_rect(Rect2i(ox + rng.randi_range(4, px - 12), rng.randi_range(4, px - 12), s, s), speck)
	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(img)
	src.texture_region_size = Vector2i(px, px)
	for d in registry.all_defs():
		if d.solid:
			src.create_tile(Vector2i(d.id, 0))
	var ts := TileSet.new()
	ts.tile_size = Vector2i(px, px)
	ts.add_source(src, TERRAIN_SOURCE)
	ts.add_source(_structure_source(px), STRUCTURE_SOURCE)
	return ts


## Structures (ladders) live on air tiles, so they share the chunk layer:
## atlas coords = (WorldGrid.Structure value, 0).
static func _structure_source(px: int) -> TileSetAtlasSource:
	var count := WorldGrid.Structure.LADDER + 1
	var img := Image.create(px * count, px, false, Image.FORMAT_RGBA8)
	var ox := WorldGrid.Structure.LADDER * px
	var rail := maxi(2, px / 10)
	var inset := px / 6
	for x in [ox + inset, ox + px - inset - rail]:
		img.fill_rect(Rect2i(x, 0, rail, px), LADDER_COLOR)
	for i in LADDER_RUNGS:
		var y := int((i + 0.5) * px / LADDER_RUNGS) - rail / 2
		img.fill_rect(Rect2i(ox + inset, y, px - 2 * inset, rail), LADDER_COLOR.lightened(0.2))
	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(img)
	src.texture_region_size = Vector2i(px, px)
	src.create_tile(Vector2i(WorldGrid.Structure.LADDER, 0))
	return src
