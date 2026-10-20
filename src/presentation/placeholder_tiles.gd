class_name PlaceholderTiles
extends RefCounted
## Builds the terrain + structure TileSet. Uses production PNGs from
## assets/production/ when present (ArtLibrary, docs/art/ASSET_SPEC.md) and
## otherwise the procedural path-B art (ProcTerrain, D-020).
##
## Atlas layout (terrain source): column = TileDef.id, row = variant. Only row 0
## holds real tiles, so WorldView keeps using atlas coords Vector2i(id, 0); a
## shared canvas shader picks row 0..VARIANTS-1 per cell from a hash of the
## tile's world position, giving variation with no extra map data.

const TERRAIN_SOURCE := 0
const STRUCTURE_SOURCE := 1
const VARIANTS := ProcTerrain.VARIANTS

const VARIANT_SHADER := """
shader_type canvas_item;
uniform float tile_px = 64.0;
uniform int variants = 4;
varying vec2 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	ivec2 cell = ivec2(floor(world_pos / tile_px));
	uint hx = uint(cell.x + 65536) * 73856093u;
	uint hy = uint(cell.y + 65536) * 19349663u;
	uint h = hx ^ hy;
	h = (h ^ (h >> 13u)) * 1274126177u;
	h = h ^ (h >> 16u);
	float v = float(h % uint(variants));
	vec2 uv = UV + vec2(0.0, v * tile_px * TEXTURE_PIXEL_SIZE.y);
	COLOR = texture(TEXTURE, uv) * COLOR;
}
"""

static var _shader: Shader


static func build_tileset(registry: TileRegistry, px: int) -> TileSet:
	var count := registry.max_id() + 1
	var img := Image.create(px * count, px * VARIANTS, false, Image.FORMAT_RGBA8)
	for d in registry.all_defs():
		if d.solid:
			for v in VARIANTS:
				img.blit_rect(terrain_tile_image(d, v, px), Rect2i(0, 0, px, px), Vector2i(d.id * px, v * px))
	var src := TileSetAtlasSource.new()
	# Padding would copy only the row-0 tiles into a padded texture and drop
	# the variant rows the shader samples.
	src.use_texture_padding = false
	src.texture = ImageTexture.create_from_image(img)
	src.texture_region_size = Vector2i(px, px)
	var mat := variant_material(px)
	for d in registry.all_defs():
		if d.solid:
			src.create_tile(Vector2i(d.id, 0))
			src.get_tile_data(Vector2i(d.id, 0), 0).material = mat
	var ts := TileSet.new()
	ts.tile_size = Vector2i(px, px)
	ts.add_source(src, TERRAIN_SOURCE)
	ts.add_source(_structure_source(px), STRUCTURE_SOURCE)
	return ts


## One px x px terrain tile: production strip cell, else procedural, else the
## old flat placeholder (materials without procedural art).
static func terrain_tile_image(d: TileDef, variant: int, px: int) -> Image:
	var strip := ArtLibrary.terrain_strip(d.key, px)
	if strip != null:
		var n := strip.get_width() / px
		return strip.get_region(Rect2i((variant % n) * px, 0, px, px))
	var img := ProcTerrain.tile(d.key, variant, px)
	if img != null:
		return img
	return _flat_tile(d, px)


static func variant_material(px: int) -> ShaderMaterial:
	if _shader == null:
		_shader = Shader.new()
		_shader.code = VARIANT_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = _shader
	mat.set_shader_parameter(&"tile_px", float(px))
	mat.set_shader_parameter(&"variants", VARIANTS)
	return mat


static func _flat_tile(d: TileDef, px: int) -> Image:
	var img := Image.create(px, px, false, Image.FORMAT_RGBA8)
	var base := d.placeholder_color
	img.fill(base.darkened(0.35))
	img.fill_rect(Rect2i(2, 2, px - 4, px - 4), base)
	return img


## Structures (ladders) live on air tiles, so they share the chunk layer:
## atlas coords = (WorldGrid.Structure value, 0).
static func _structure_source(px: int) -> TileSetAtlasSource:
	var count := WorldGrid.Structure.LADDER + 1
	var img := Image.create(px * count, px, false, Image.FORMAT_RGBA8)
	var ladder := ArtLibrary.tile_image(ArtLibrary.structure_path(&"ladder"), px)
	if ladder == null:
		ladder = ProcTerrain.ladder(px)
	img.blit_rect(ladder, Rect2i(0, 0, px, px), Vector2i(WorldGrid.Structure.LADDER * px, 0))
	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(img)
	src.texture_region_size = Vector2i(px, px)
	src.create_tile(Vector2i(WorldGrid.Structure.LADDER, 0))
	return src
