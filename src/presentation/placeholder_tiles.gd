class_name PlaceholderTiles
extends RefCounted
## Runtime-generated flat-color tiles. Obviously not final art; replaced when
## the Visual Design asset specification is approved (ASSET_CONVENTIONS.md).


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
	ts.add_source(src, 0)
	return ts
