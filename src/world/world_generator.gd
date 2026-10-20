class_name WorldGenerator
extends RefCounted
## Deterministic seed-based terrain generation (spec §2). Same seed + size +
## GEN_VERSION must always give the same tiles. Any change to the output of
## this file requires bumping GEN_VERSION and a DECISIONS.md entry.
## M1 scope: surface, dirt, rock, ore veins, bedrock border. No caves (M7).

const GEN_VERSION := 1

const PRESETS := {
	&"small": Vector2i(384, 192),
	&"medium": Vector2i(512, 256),
	&"large": Vector2i(1024, 384),
}
const DEFAULT_PRESET := &"medium"
const BEDROCK_ROWS := 2


static func generate(world_seed: int, size: Vector2i, registry: TileRegistry) -> WorldGrid:
	var w := size.x
	var h := size.y
	var grid := WorldGrid.new(w, h, registry)
	var surface_noise := _noise(world_seed, 1, 0.012, 3)
	var dirt_noise := _noise(world_seed, 2, 0.05, 2)
	var iron_noise := _noise(world_seed, 3, 0.09, 2)
	var gold_noise := _noise(world_seed, 4, 0.11, 1)
	var crystal_noise := _noise(world_seed, 5, 0.13, 1)

	var t := PackedByteArray()
	t.resize(w * h)
	var surface := PackedInt32Array()
	surface.resize(w)
	var base := int(h * 0.16)
	var amp := h * 0.05
	for x in w:
		var s := clampi(base + int(roundf(surface_noise.get_noise_1d(x) * amp)), 4, h / 3)
		surface[x] = s
		var dirt_depth := 10 + int((dirt_noise.get_noise_1d(x) + 1.0) * 6.0)
		for y in range(s, h):
			var id := TileRegistry.DIRT
			if y >= s + dirt_depth:
				id = TileRegistry.ROCK
				var depth := float(y) / h
				if depth > 0.65 and crystal_noise.get_noise_2d(x, y) > 0.55:
					id = TileRegistry.CRYSTAL
				elif depth > 0.4 and gold_noise.get_noise_2d(x, y) > 0.5:
					id = TileRegistry.GOLD_ORE
				elif iron_noise.get_noise_2d(x, y) > 0.45:
					id = TileRegistry.IRON_ORE
			t[y * w + x] = id
	# Bedrock: bottom rows, and side walls below the surface.
	for y in range(h - BEDROCK_ROWS, h):
		for x in w:
			t[y * w + x] = TileRegistry.BEDROCK
	for x in [0, w - 1]:
		for y in range(surface[x], h):
			t[y * w + x] = TileRegistry.BEDROCK
	grid.tiles = t  # structures stay as allocated by WorldGrid (all NONE)
	grid.surface_y = surface
	return grid


## Player seed text -> seed. Integers are used as-is; other text is hashed;
## blank picks a random seed.
static func seed_from_text(text: String) -> int:
	var s := text.strip_edges()
	if s.is_empty():
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		return rng.randi() & 0x7fffffff
	if s.is_valid_int():
		return absi(s.to_int()) & 0x7fffffff
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(s.to_utf8_buffer())
	return ctx.finish().decode_u32(0) & 0x7fffffff


static func _noise(world_seed: int, salt: int, freq: float, octaves: int) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.seed = (world_seed * 31 + salt * 1000003) & 0x7fffffff
	n.frequency = freq
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = octaves
	return n
