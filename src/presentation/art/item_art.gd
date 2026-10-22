class_name ItemArt
extends RefCounted
## Procedural item art (ground piles and carried items) for every MaterialDefs
## key (M4A-QA-4): ores / soil are rough chunks, food has its own shapes
## (mushroom cap, meal bowl, ration tin). Colours come from the palette, then
## MaterialDefs, then tile defs, and never fall back to magenta.

const P := preload("res://src/presentation/art/art_palette.gd")
## Last-resort colour for an unknown material (neutral, clearly "some item").
const UNKNOWN := Color(0.62, 0.6, 0.56)

static var _materials: MaterialDefs


static func materials() -> MaterialDefs:
	if _materials == null:
		_materials = MaterialDefs.load_default()
	return _materials


## Display colour of a material key.
static func color_for(reg: TileRegistry, material: StringName) -> Color:
	match material:
		&"dirt":
			return P.DIRT_LIGHT
		&"rock":
			return P.ROCK_LIGHT
		&"iron_ore":
			return P.IRON
		&"gold_ore":
			return P.GOLD
		&"crystal":
			return P.CRYSTAL
	var mats := materials()
	if mats != null and mats.has(material):
		return mats.get_def(material).color
	if reg != null:
		for d in reg.all_defs():
			if d.key == material:
				return d.placeholder_color
	return UNKNOWN


## Draws one item of `material` centred at c, radius r (rough size).
static func draw(ci: CanvasItem, material: StringName, c: Vector2, r: float, col: Color, s: int) -> void:
	match material:
		&"mushroom":
			_mushroom(ci, c, r, col)
		&"meal":
			_meal(ci, c, r, col)
		&"ration":
			_ration(ci, c, r, col)
		_:
			ProcFigure.draw_chunk(ci, c, r, col, s)


static func _mushroom(ci: CanvasItem, c: Vector2, r: float, col: Color) -> void:
	var o := 2.0
	# Stem.
	var stem := Rect2(c + Vector2(-r * 0.28, -r * 0.15), Vector2(r * 0.56, r * 0.85))
	ci.draw_rect(stem.grow(o), P.OUTLINE)
	ci.draw_rect(stem, Color("#efe4cf"))
	# Cap: half ellipse with spots.
	var cap := PackedVector2Array()
	for i in 13:
		var a := PI + PI * i / 12.0
		cap.append(c + Vector2(cos(a) * r, sin(a) * r * 0.75) + Vector2(0, -r * 0.1))
	var outline := PackedVector2Array()
	for p in cap:
		outline.append(c + (p - c) * (1.0 + o / r))
	ci.draw_colored_polygon(outline, P.OUTLINE)
	ci.draw_colored_polygon(cap, Color("#c8553d"))
	ci.draw_circle(c + Vector2(-r * 0.35, -r * 0.45), r * 0.14, Color("#f4ead6"))
	ci.draw_circle(c + Vector2(r * 0.3, -r * 0.55), r * 0.11, Color("#f4ead6"))
	ci.draw_circle(c + Vector2(r * 0.02, -r * 0.3), r * 0.09, Color("#f4ead6"))


static func _meal(ci: CanvasItem, c: Vector2, r: float, col: Color) -> void:
	var o := 2.0
	# Food heap above the rim.
	ci.draw_circle(c + Vector2(0, -r * 0.15), r * 0.62 + o, P.OUTLINE)
	ci.draw_circle(c + Vector2(0, -r * 0.15), r * 0.62, col)
	ci.draw_circle(c + Vector2(-r * 0.2, -r * 0.35), r * 0.18, col.lightened(0.3))
	ci.draw_circle(c + Vector2(r * 0.25, -r * 0.25), r * 0.12, Color("#6fae4a"))
	# Bowl: lower half ellipse.
	var bowl := PackedVector2Array()
	for i in 13:
		var a := PI * i / 12.0
		bowl.append(c + Vector2(cos(a) * r, sin(a) * r * 0.7))
	var outline := PackedVector2Array()
	for p in bowl:
		outline.append(c + (p - c) * (1.0 + o / r))
	ci.draw_colored_polygon(outline, P.OUTLINE)
	ci.draw_colored_polygon(bowl, Color("#e9e2d4"))
	ci.draw_line(c + Vector2(-r, 0), c + Vector2(r, 0), P.OUTLINE, o)
	ci.draw_line(c + Vector2(-r * 0.6, r * 0.25), c + Vector2(r * 0.6, r * 0.25), Color("#4b6288"), maxf(1.0, r * 0.12))


static func _ration(ci: CanvasItem, c: Vector2, r: float, col: Color) -> void:
	var o := 2.0
	var tin := Rect2(c + Vector2(-r * 0.75, -r * 0.6), Vector2(r * 1.5, r * 1.15))
	ci.draw_rect(tin.grow(o), P.OUTLINE)
	ci.draw_rect(tin, Color("#9aa0a6"))
	# Label band in the material colour (olive) with a light stripe.
	var band := Rect2(tin.position + Vector2(0, tin.size.y * 0.25), Vector2(tin.size.x, tin.size.y * 0.5))
	ci.draw_rect(band, col)
	ci.draw_rect(Rect2(band.position + Vector2(tin.size.x * 0.2, band.size.y * 0.35), Vector2(tin.size.x * 0.6, band.size.y * 0.3)), col.lightened(0.45))
	# Lid rim.
	ci.draw_rect(Rect2(tin.position, Vector2(tin.size.x, maxf(1.0, r * 0.14))), Color("#c9cdd1"))
