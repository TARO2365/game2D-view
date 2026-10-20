class_name ProcTerrain
extends RefCounted
## Procedural (path B, D-020) terrain and ladder tiles drawn in code once per
## run: textured materials, chunky darker rims, readable ore sparkles, several
## variants per material. Deterministic: same (material, variant, px) -> same
## pixels. Matched against the concept palette (ArtPalette).

const P := preload("res://src/presentation/art/art_palette.gd")

## Variants per material (rows of the terrain atlas, ASSET_SPEC §5).
const VARIANTS := 4

static var _cache: Dictionary = {}  # "key|variant|px" -> Image


## Tile image (RGBA8, px x px) for a material key; null for unknown keys.
static func tile(material: StringName, variant: int, px: int) -> Image:
	var ck := "%s|%d|%d" % [material, variant, px]
	if _cache.has(ck):
		return _cache[ck]
	var cv := PixelCanvas.new(px, px)
	var s := (String(material).hash() & 0xFFFF) * 31 + variant * 7 + 1
	match material:
		&"dirt":
			_dirt(cv, px, s)
		&"rock":
			_rock(cv, px, s, P.ROCK, P.ROCK_DARK, P.ROCK_LIGHT)
		&"iron_ore":
			_rock(cv, px, s, Color("#50555c"), Color("#33363b"), Color("#6f747a"))
			_iron(cv, px, s)
		&"gold_ore":
			_rock(cv, px, s, Color("#5a4632"), Color("#3a2c1f"), Color("#7a634a"))
			_gold(cv, px, s)
		&"crystal":
			_rock(cv, px, s, Color("#3e2e48"), Color("#261b2e"), Color("#56426a"))
			_crystal(cv, px, s)
		&"bedrock":
			_bedrock(cv, px, s)
		&"concrete":
			_concrete(cv, px, s, variant)
		_:
			return null
	if material != &"concrete":
		_rim(cv, px)
	var img := cv.to_image()
	_cache[ck] = img
	return img


## Ladder tile (transparent background): two wooden rails, rungs evenly
## spaced so stacked ladders line up, bolts at the joints.
static func ladder(px: int) -> Image:
	var ck := "ladder|%d" % px
	if _cache.has(ck):
		return _cache[ck]
	var cv := PixelCanvas.new(px, px)
	var u := px / 64.0
	var rail := maxi(3, roundi(7 * u))
	var inset := roundi(12 * u)
	var rungs := 3
	for i in rungs:
		var y := roundi((i + 0.5) * px / float(rungs)) - roundi(3 * u)
		var rh := maxi(3, roundi(6 * u))
		cv.rect(inset, y - 1, px - 2 * inset, rh + 2, P.WOOD_DARK)
		cv.rect(inset, y, px - 2 * inset, rh, P.WOOD)
		cv.rect(inset, y, px - 2 * inset, maxi(1, roundi(2 * u)), P.WOOD_LIGHT)
	for x in [inset - roundi(2 * u), px - inset - rail + roundi(2 * u)]:
		cv.rect(x - 1, 0, rail + 2, px, P.WOOD_DARK)
		cv.rect(x, 0, rail, px, P.WOOD)
		cv.rect(x + 1, 0, maxi(1, roundi(2 * u)), px, P.WOOD_LIGHT)
		for i in rungs:
			var y := roundi((i + 0.5) * px / float(rungs))
			cv.ellipse(x + rail / 2.0, y, 2.2 * u, 2.2 * u, Color("#c8c2b8"))
	var img := cv.to_image()
	_cache[ck] = img
	return img


# --- Materials ----------------------------------------------------------------

## Opaque mottled base: tileable value noise (precomputed lattice) + grain.
## Writes bytes directly — this loop dominates tileset build time.
static func _base(cv: PixelCanvas, px: int, s: int, dark: Color, mid: Color, light: Color, cell: int) -> void:
	var g := maxi(1, px / cell)
	var lattice := PackedFloat32Array()
	lattice.resize(g * g)
	for j in g:
		for i in g:
			lattice[j * g + i] = PixelCanvas.hash01(i, j, s)
	var ramp := PackedByteArray()  # 32-step colour ramp dark -> mid -> light
	for r in 32:
		var n := r / 31.0
		var c: Color
		if n < 0.62:
			c = dark.lerp(mid, clampf(n * 1.6, 0.0, 1.0))
		else:
			c = mid.lerp(light, clampf((n - 0.62) * 2.6, 0.0, 1.0))
		ramp.append_array([c.r8, c.g8, c.b8])
	var d := cv.data
	var inv := 1.0 / cell
	for y in px:
		var gy := y * inv
		var iy := floori(gy)
		var fy := gy - iy
		fy = fy * fy * (3.0 - 2.0 * fy)
		var r0 := (iy % g) * g
		var r1 := ((iy + 1) % g) * g
		for x in px:
			var gx := x * inv
			var ix := floori(gx)
			var fx := gx - ix
			fx = fx * fx * (3.0 - 2.0 * fx)
			var x0 := ix % g
			var x1 := (ix + 1) % g
			var n := lerpf(lerpf(lattice[r0 + x0], lattice[r0 + x1], fx), lerpf(lattice[r1 + x0], lattice[r1 + x1], fx), fy)
			n = n * 0.72 + PixelCanvas.hash01(x, y, s + 9) * 0.28
			var k := clampi(int(n * 31.0), 0, 31) * 3
			var o := (y * px + x) * 4
			d[o] = ramp[k]
			d[o + 1] = ramp[k + 1]
			d[o + 2] = ramp[k + 2]
			d[o + 3] = 255
	cv.data = d


static func _dirt(cv: PixelCanvas, px: int, s: int) -> void:
	var u := px / 64.0
	_base(cv, px, s, P.DIRT_DARK, P.DIRT, P.DIRT_LIGHT, maxi(4, px / 4))
	var rng := RandomNumberGenerator.new()
	rng.seed = s
	for i in 9:
		var x := rng.randf_range(5, px - 5)
		var y := rng.randf_range(5, px - 5)
		var r := rng.randf_range(1.6, 3.4) * u
		cv.ellipse(x, y + 1, r + 1, r * 0.8 + 1, Color("#3e2817"))
		cv.ellipse(x, y, r, r * 0.8, Color("#8c7a68") if i % 3 == 0 else Color("#6a4a33"))
		cv.put(roundi(x - r * 0.4), roundi(y - r * 0.4), Color(1, 1, 1, 0.35))
	for i in 3:
		var x0 := rng.randi_range(6, px - 6)
		var y0 := rng.randi_range(6, px - 6)
		cv.line(x0, y0, x0 + rng.randi_range(-8, 8), y0 + rng.randi_range(3, 9), Color("#4a3020", 0.7))


static func _rock(cv: PixelCanvas, px: int, s: int, mid: Color, dark: Color, light: Color) -> void:
	var u := px / 64.0
	_base(cv, px, s, dark, mid, mid.lerp(light, 0.5), maxi(4, px / 4))
	var rng := RandomNumberGenerator.new()
	rng.seed = s + 101
	# Cobbles: dark outline, lighter body, top-left highlight.
	for i in 6:
		var x := rng.randf_range(8, px - 8)
		var y := rng.randf_range(8, px - 8)
		var rx := rng.randf_range(7.0, 12.0) * u
		var ry := rx * rng.randf_range(0.6, 0.85)
		cv.ellipse(x, y + 1, rx + 1.5, ry + 1.5, dark.darkened(0.25))
		cv.ellipse(x, y, rx, ry, mid.lerp(light, 0.45))
		cv.ellipse(x - rx * 0.25, y - ry * 0.3, rx * 0.5, ry * 0.35, light.lerp(Color.WHITE, 0.08))
	cv.line(rng.randi_range(4, px - 4), 2, rng.randi_range(4, px - 4), px - 3, Color(dark.darkened(0.3), 0.55))


static func _iron(cv: PixelCanvas, px: int, s: int) -> void:
	var u := px / 64.0
	var rng := RandomNumberGenerator.new()
	rng.seed = s + 202
	for i in 4:
		var x := rng.randf_range(12, px - 12)
		var y := rng.randf_range(12, px - 12)
		for k in 3:
			var hw := rng.randf_range(3.0, 5.5) * u
			var hh := hw * rng.randf_range(1.2, 1.8)
			var cx := x + rng.randf_range(-6, 6) * u
			var cy := y + rng.randf_range(-5, 5) * u
			cv.diamond(cx, cy, hw + 1.5, hh + 1.5, Color("#1d2a3c"), Color("#1d2a3c"))
			cv.diamond(cx, cy, hw, hh, P.IRON, P.IRON_LIGHT)
		_sparkle(cv, roundi(x + 3 * u), roundi(y - 5 * u), u, Color("#e6f8ff"))


static func _gold(cv: PixelCanvas, px: int, s: int) -> void:
	var u := px / 64.0
	var rng := RandomNumberGenerator.new()
	rng.seed = s + 303
	for i in 5:
		var x := rng.randf_range(10, px - 10)
		var y := rng.randf_range(10, px - 10)
		var r := rng.randf_range(3.5, 6.0) * u
		cv.ellipse(x, y + 1, r + 1.5, r * 0.8 + 1.5, P.GOLD_DARK)
		cv.ellipse(x, y, r, r * 0.8, P.GOLD)
		cv.ellipse(x - r * 0.3, y - r * 0.3, r * 0.45, r * 0.35, P.GOLD_LIGHT)
	for i in 3:
		_sparkle(cv, rng.randi_range(8, px - 8), rng.randi_range(8, px - 8), u, Color("#fffbe0"))


static func _crystal(cv: PixelCanvas, px: int, s: int) -> void:
	var u := px / 64.0
	var rng := RandomNumberGenerator.new()
	rng.seed = s + 404
	for i in 3:
		var x := rng.randf_range(12, px - 12)
		var y := rng.randf_range(14, px - 10)
		cv.ellipse(x, y, 13 * u, 11 * u, Color(P.CRYSTAL, 0.18))
		for k in 3:
			var hw := rng.randf_range(2.5, 4.0) * u
			var hh := rng.randf_range(7.0, 11.0) * u
			var cx := x + (k - 1) * 5.0 * u
			var cy := y - hh * 0.4 + absi(k - 1) * 3.0 * u
			cv.diamond(cx, cy, hw + 1.5, hh + 1.5, P.CRYSTAL_DARK, P.CRYSTAL_DARK)
			cv.diamond(cx, cy, hw, hh, P.CRYSTAL, P.CRYSTAL_LIGHT)
		_sparkle(cv, roundi(x - 2 * u), roundi(y - 9 * u), u, Color("#fff0ff"))


static func _bedrock(cv: PixelCanvas, px: int, s: int) -> void:
	_base(cv, px, s, Color("#161314"), P.BEDROCK, P.BEDROCK_LIGHT, maxi(4, px / 2))
	var rng := RandomNumberGenerator.new()
	rng.seed = s + 505
	for i in 4:
		var x0 := rng.randi_range(2, px - 2)
		var y0 := rng.randi_range(2, px - 2)
		var x1 := x0 + rng.randi_range(-14, 14)
		var y1 := y0 + rng.randi_range(-14, 14)
		cv.line(x0, y0, x1, y1, Color("#0c0a0b"))
		cv.line(x0 + 1, y0, x1 + 1, y1, Color(P.BEDROCK_LIGHT, 0.6))


static func _concrete(cv: PixelCanvas, px: int, s: int, variant: int) -> void:
	var u := px / 64.0
	_base(cv, px, s, P.CONCRETE_DARK.lerp(P.CONCRETE, 0.6), P.CONCRETE, P.CONCRETE_LIGHT, maxi(2, px / 16))
	var b := maxi(2, roundi(3 * u))
	# Panel frame: dark outer border, highlight just inside, dark seam inside.
	for i in b:
		var f := 0.55 + 0.12 * i
		for k in px:
			cv.shade(k, i, f)
			cv.shade(k, px - 1 - i, f * 0.9)
			cv.shade(i, k, f)
			cv.shade(px - 1 - i, k, f * 0.9)
	cv.rect(b, b, px - 2 * b, 1, Color(1, 1, 1, 0.35))
	var seam := roundi(px * 0.5)
	cv.rect(b + 2, seam, px - 2 * b - 4, 1, Color(0, 0, 0, 0.28))
	cv.rect(b + 2, seam + 1, px - 2 * b - 4, 1, Color(1, 1, 1, 0.18))
	for c in [Vector2(b + 4 * u, b + 4 * u), Vector2(px - b - 4 * u, b + 4 * u),
			Vector2(b + 4 * u, px - b - 4 * u), Vector2(px - b - 4 * u, px - b - 4 * u)]:
		cv.ellipse(c.x, c.y + 0.5, 2.4 * u, 2.4 * u, Color("#4c5055"))
		cv.ellipse(c.x - 0.5, c.y - 0.5, 1.2 * u, 1.2 * u, Color("#d0d3d6"))
	var rng := RandomNumberGenerator.new()
	rng.seed = s + 606
	if variant == 1:
		cv.ellipse(rng.randf_range(16, px - 16), rng.randf_range(20, px - 14), 10 * u, 6 * u, Color(0.25, 0.2, 0.15, 0.18))
	elif variant == 2:
		var x0 := rng.randi_range(14, px - 14)
		cv.line(x0, b + 3, x0 + 5, roundi(px * 0.4), Color(0, 0, 0, 0.35))


static func _sparkle(cv: PixelCanvas, x: int, y: int, u: float, c: Color) -> void:
	var arm := maxi(2, roundi(3 * u))
	for k in range(-arm, arm + 1):
		var a := 1.0 - absf(k) / float(arm + 1)
		cv.put(x + k, y, Color(c, a))
		cv.put(x, y + k, Color(c, a))


## Darker chunky rim + soft top highlight so each block reads at a glance.
static func _rim(cv: PixelCanvas, px: int) -> void:
	var edge := [0, 1, 2, px - 3, px - 2, px - 1]
	for y in px:
		var xs: Array = range(px) if (y < 5 or y >= px - 3) else edge
		for x in xs:
			var d := mini(mini(x, y), mini(px - 1 - x, px - 1 - y))
			if d == 0:
				cv.shade(x, y, 0.62)
			elif d < 3:
				cv.shade(x, y, 0.84)
			elif y < 5:
				cv.shade(x, y, 1.08)
