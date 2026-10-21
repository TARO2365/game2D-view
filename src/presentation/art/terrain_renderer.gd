class_name TerrainRenderer
extends RefCounted
## ONI-style terrain (D-027 step 2). One quad per chunk drawn with a canvas
## shader that reads a small per-chunk data texture ((CHUNK+2)^2 cells incl.
## a 1-cell border: R = material id, G = structure id, B = underground air)
## and a Texture2DArray of world-space material textures. In the shader:
## - a bilinear "solidity" field over cell centres gives rounded, organic
##   edges (noise-perturbed threshold) while straight runs stay on the grid;
## - materials meet along noisy borders with a dark seam;
## - exposed edges get a dark outline and a light top highlight;
## - dug (underground) air next to rock gets a soft cavity shadow;
## - everything darkens slightly with depth; ladders are drawn in the same pass.
## Built concrete stays square, mapped one panel per tile.
## Only the data texture of an edited chunk (and neighbours whose border
## cells changed) is rewritten — ~1k cells, no re-meshing.

const BORDER := 1
## World tiles covered by one repeat of a natural material texture.
const TEX_TILES := 4.0
const HD_SIZE := 512
const MAX_LAYERS := 16

const SHADER := """
shader_type canvas_item;

uniform sampler2DArray materials : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D ladder_tex : source_color, filter_linear;
uniform sampler2D data_tex : filter_nearest;
uniform float tile_px = 64.0;
uniform float periods[16];
uniform float world_h_px = 16384.0;
uniform float depth_dark = 0.28;
uniform int concrete_id = 7;
uniform int ladder_id = 1;

varying vec2 local_pos;
varying vec2 world_pos;

void vertex() {
	local_pos = VERTEX;
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

vec3 cell(ivec2 c) {
	ivec2 s = textureSize(data_tex, 0) - ivec2(1);
	return texelFetch(data_tex, clamp(c + ivec2(1), ivec2(0), s), 0).rgb;
}

int mat_at(ivec2 c) {
	return int(cell(c).r * 255.0 + 0.5);
}

float solid(ivec2 c) {
	return mat_at(c) > 0 ? 1.0 : 0.0;
}

// Bilinear solidity over cell centres; p in cells.
float field(vec2 p) {
	vec2 q = p - 0.5;
	ivec2 i = ivec2(floor(q));
	vec2 t = q - floor(q);
	float a = solid(i);
	float b = solid(i + ivec2(1, 0));
	float c = solid(i + ivec2(0, 1));
	float e = solid(i + ivec2(1, 1));
	return mix(mix(a, b, t.x), mix(c, e, t.x), t.y);
}

// Solid material with the largest bilinear weight around p (for filled corners).
int nearest_solid(vec2 p) {
	vec2 q = p - 0.5;
	ivec2 i = ivec2(floor(q));
	vec2 t = q - floor(q);
	float w[4] = float[4]((1.0 - t.x) * (1.0 - t.y), t.x * (1.0 - t.y), (1.0 - t.x) * t.y, t.x * t.y);
	ivec2 o[4] = ivec2[4](ivec2(0), ivec2(1, 0), ivec2(0, 1), ivec2(1, 1));
	int best = 0;
	float bw = -1.0;
	for (int k = 0; k < 4; k++) {
		int m = mat_at(i + o[k]);
		if (m > 0 && w[k] > bw) { bw = w[k]; best = m; }
	}
	return best;
}

// Material at p with a noisy offset, so material borders are organic.
int jittered(vec2 p, vec2 wp, int fallback) {
	vec2 j = vec2(vnoise(wp / 19.0), vnoise(wp / 19.0 + 37.0)) - 0.5;
	int m = mat_at(ivec2(floor(p + j * 0.8)));
	return (m > 0 && m != concrete_id) ? m : fallback;
}

void fragment() {
	vec2 p = local_pos / tile_px;
	ivec2 c = ivec2(floor(p));
	vec3 own_v = cell(c);
	int own = int(own_v.r * 255.0 + 0.5);
	int st = int(own_v.g * 255.0 + 0.5);
	bool under = own_v.b > 0.5;

	float n = (vnoise(world_pos / 23.0) - 0.5) * 0.30 + (vnoise(world_pos / 7.0) - 0.5) * 0.10;
	float th = 0.5 + n;
	float f = field(p);
	float aa = max(fwidth(f), 0.002);

	vec4 terrain = vec4(0.0);
	int m = 0;
	float alpha = 0.0;
	if (own == concrete_id) {
		m = own;
		alpha = 1.0;
	} else {
		alpha = smoothstep(th - aa, th + aa, f);
		if (own > 0) {
			m = jittered(p, world_pos, own);
		} else {
			m = nearest_solid(p);
			if (m == concrete_id) { alpha = 0.0; }
		}
	}
	if (alpha > 0.0 && m > 0) {
		float per = periods[m] * tile_px;
		vec3 col = texture(materials, vec3(world_pos / per, float(m))).rgb;
		if (m != concrete_id) {
			// Dark rim and soft inner cavity toward exposed edges.
			col *= mix(0.30, 1.0, smoothstep(th, th + 0.07, f));
			col *= mix(0.78, 1.0, smoothstep(th, th + 0.45, f));
			// Light top highlight where air is just above.
			float fu = field(p - vec2(0.0, 7.0 / tile_px));
			float top = clamp((th - fu) * 5.0, 0.0, 1.0) * (1.0 - smoothstep(th + 0.06, th + 0.22, f))
					* smoothstep(th + 0.04, th + 0.08, f);
			col = mix(col, col * 1.5 + vec3(0.05), top * 0.75);
			// Seam between two different materials.
			int mx = jittered(p + vec2(2.0 / tile_px, 0.0), world_pos + vec2(2.0, 0.0), m);
			int my = jittered(p + vec2(0.0, 2.0 / tile_px), world_pos + vec2(0.0, 2.0), m);
			if (mx != m || my != m) { col *= 0.55; }
		}
		col *= 1.0 - depth_dark * clamp(world_pos.y / world_h_px, 0.0, 1.0);
		terrain = vec4(col, alpha);
	}
	// Underground air: soft cavity shadow near rock, ladders on top.
	vec4 back = vec4(0.0);
	if (own == 0 && under) {
		back = vec4(0.0, 0.0, 0.0, smoothstep(0.0, 0.5, f) * 0.55);
	}
	if (own == 0 && st == ladder_id) {
		vec4 l = texture(ladder_tex, fract(p));
		back = vec4(mix(back.rgb, l.rgb, l.a), max(back.a, l.a));
	}
	vec4 outc = back;
	outc.rgb = mix(back.rgb * back.a, terrain.rgb, terrain.a);
	outc.a = terrain.a + back.a * (1.0 - terrain.a);
	if (outc.a > 0.0) { outc.rgb /= outc.a; }
	COLOR = outc;
}
"""

static var _shader: Shader
static var _materials: Dictionary = {}  # "px|base_dir" -> Texture2DArray
static var _periods: Dictionary = {}


static func data_size() -> int:
	return WorldGrid.CHUNK_SIZE + 2 * BORDER


## Fresh (CHUNK+2)^2 RGB8 data image for chunk c.
static func chunk_image(grid: WorldGrid, c: Vector2i) -> Image:
	var n := data_size()
	return Image.create_from_data(n, n, false, Image.FORMAT_RGB8, chunk_data(grid, c))


## Raw RGB8 bytes of chunk c's data texture (edge cells clamp at the world border).
static func chunk_data(grid: WorldGrid, c: Vector2i) -> PackedByteArray:
	var n := data_size()
	var ox := c.x * WorldGrid.CHUNK_SIZE - BORDER
	var oy := c.y * WorldGrid.CHUNK_SIZE - BORDER
	var w := grid.width
	var h := grid.height
	var tiles := grid.tiles
	var st := grid.structures
	var surf := grid.surface_y
	var data := PackedByteArray()
	data.resize(n * n * 3)
	var o := 0
	for y in n:
		var gy := clampi(oy + y, 0, h - 1)
		var row := gy * w
		for x in n:
			var gx := clampi(ox + x, 0, w - 1)
			var i := row + gx
			var id: int = tiles[i]
			data[o] = id
			data[o + 1] = st[i]
			data[o + 2] = 255 if (id == TileRegistry.AIR and gy >= surf[gx]) else 0
			o += 3
	return data


## Shared ShaderMaterial for tile size px (one per WorldView).
static func make_material(registry: TileRegistry, px: int, world_h_px: float) -> ShaderMaterial:
	if _shader == null:
		_shader = Shader.new()
		_shader.code = SHADER
	var key := "%d|%s" % [px, ArtLibrary.base_dir]
	if not _materials.has(key):
		_build_layers(registry, px, key)
	var mat := ShaderMaterial.new()
	mat.shader = _shader
	mat.set_shader_parameter(&"materials", _materials[key])
	mat.set_shader_parameter(&"periods", _periods[key])
	mat.set_shader_parameter(&"tile_px", float(px))
	mat.set_shader_parameter(&"world_h_px", world_h_px)
	mat.set_shader_parameter(&"concrete_id", TileRegistry.CONCRETE)
	mat.set_shader_parameter(&"ladder_id", WorldGrid.Structure.LADDER)
	var ladder := ArtLibrary.tile_image(ArtLibrary.structure_path(&"ladder"), px)
	if ladder == null:
		ladder = ProcTerrain.ladder(px)
	mat.set_shader_parameter(&"ladder_tex", ImageTexture.create_from_image(ladder))
	return mat


## Layer i = material id i: the owner's high-res seamless texture
## (terrain_hd/terrain_<key>.png, repeats every TEX_TILES tiles) or, without
## it, the 64 px tile (production strip or procedural) repeating every tile.
static func _build_layers(registry: TileRegistry, px: int, key: String) -> void:
	var images: Array[Image] = []
	var periods := PackedFloat32Array()
	periods.resize(MAX_LAYERS)
	periods.fill(1.0)
	var layers := mini(registry.max_id() + 1, MAX_LAYERS)
	for id in layers:
		var d := registry.get_def(id)
		var img: Image = null
		if d != null and d.solid:
			img = ArtLibrary.image(hd_path(d.key))
			if img != null:
				periods[id] = 1.0 if id == TileRegistry.CONCRETE else TEX_TILES
			else:
				img = PlaceholderTiles.terrain_tile_image(d, 0, px)
		if img == null:
			img = Image.create(HD_SIZE, HD_SIZE, false, Image.FORMAT_RGBA8)
			img.fill(Color(0.3, 0.25, 0.2))
		img = img.duplicate() as Image
		img.convert(Image.FORMAT_RGBA8)
		if img.get_size() != Vector2i(HD_SIZE, HD_SIZE):
			img.resize(HD_SIZE, HD_SIZE, Image.INTERPOLATE_LANCZOS if img.get_width() > HD_SIZE else Image.INTERPOLATE_CUBIC)
		img.generate_mipmaps()
		images.append(img)
	var arr := Texture2DArray.new()
	arr.create_from_images(images)
	_materials[key] = arr
	_periods[key] = periods


static func hd_path(material: StringName) -> String:
	return "terrain_hd/terrain_%s.png" % material


static func clear_cache() -> void:
	_materials.clear()
	_periods.clear()
