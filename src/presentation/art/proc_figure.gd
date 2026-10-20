class_name ProcFigure
extends RefCounted
## Procedural chibi colonist (path B, D-020) as a cut-out rig: each body part
## is a child Node2D whose drawing is recorded once; animation only moves /
## rotates the parts (no redraw per frame), so 100 NPCs stay cheap.
## Design space = 96x192 cell (ASSET_SPEC §6): origin = feet bottom-centre,
## y up is negative, character ~160 units tall, head ~40 % of the height,
## facing +x. The rig root is scaled by the caller for tile size / facing.

const P := preload("res://src/presentation/art/art_palette.gd")

const ROLES: Array[StringName] = [&"miner", &"technician", &"scientist", &"cook"]
## Procedural animation frame counts (production sheets use their own).
const FRAMES := {&"idle": 3, &"walk": 4, &"carry": 4, &"climb": 4, &"dig": 4}
const ARM_LEN := 24.0
const LEG_LEN := 29.0
const HEAD_R := 30.0
const OUTLINE_W := 3.0
const SHOULDER_B := Vector2(-9, -74)
const SHOULDER_F := Vector2(9, -74)
const HIP_B := Vector2(-6, -38)
const HIP_F := Vector2(6, -38)
const CARRY_AT := Vector2(17, -64)
const NO_CARRY := Color(0, 0, 0, 0)


## One rig part: draws itself with `painter(part)`; redraws only when its
## `blink` or `tint` changes.
class Part extends Node2D:
	var painter: Callable
	var blink := false:
		set(v):
			if v != blink:
				blink = v
				queue_redraw()
	var tint := Color.WHITE:
		set(v):
			if v != tint:
				tint = v
				queue_redraw()

	func _draw() -> void:
		painter.call(self)


## Visual identity of one NPC, derived from its stable id (cosmetic only;
## roles are not a gameplay concept yet).
static func look_for_id(id: String, accent: Color) -> Dictionary:
	var n := id.get_slice(":", 1).to_int() if id.contains(":") else absi(id.hash())
	var role := ROLES[posmod(n, ROLES.size())]
	var h := absi(("%s#look" % id).hash())
	var skin: Color = P.SKIN_TONES[h % P.SKIN_TONES.size()]
	var hair: Color = P.HAIR_COLORS[(h / 7) % P.HAIR_COLORS.size()]
	var shirt: Color
	var pants: Color
	match role:
		&"miner":
			shirt = Color("#6b5a3a").lerp(accent, 0.25)
			pants = Color("#5b4a36")
		&"technician":
			shirt = P.STEEL_BLUE.lerp(accent, 0.25)
			pants = P.STEEL_BLUE.darkened(0.3)
		&"scientist":
			shirt = P.COAT_WHITE
			pants = P.SLATE
		_:
			shirt = P.COAT_WHITE
			pants = Color("#2f3238")
	return {
		&"role": role, &"skin": skin, &"hair": hair, &"shirt": shirt,
		&"sleeve": shirt.darkened(0.12), &"pants": pants, &"accent": accent,
	}


## Pose of one frame. Swings are radians, + = toward facing (0 = hanging
## down); lifts raise a foot; bob moves the upper body (+ = down).
static func pose(anim: StringName, frame: int) -> Dictionary:
	var f := posmod(frame, FRAMES.get(anim, 1))
	var p := {&"bob": 0.0, &"leg_b": 0.0, &"leg_f": 0.0, &"lift_b": 0.0, &"lift_f": 0.0,
			&"arm_b": -0.15, &"arm_f": 0.15, &"tool": false, &"hold": false, &"blink": false}
	match anim:
		&"idle":
			p[&"bob"] = 1.0 if f == 1 else 0.0
			p[&"blink"] = f == 2
		&"walk", &"carry":
			var swing := [0.4, 0.0, -0.4, 0.0]
			p[&"leg_f"] = swing[f]
			p[&"leg_b"] = swing[(f + 2) % 4]
			p[&"lift_f"] = 3.0 if f == 1 else 0.0
			p[&"lift_b"] = 3.0 if f == 3 else 0.0
			p[&"bob"] = -2.0 if f % 2 == 1 else 0.0
			if anim == &"walk":
				p[&"arm_f"] = -float(swing[f]) * 1.2
				p[&"arm_b"] = float(swing[f]) * 1.2
			else:
				p[&"arm_f"] = 1.25
				p[&"arm_b"] = 1.4
				p[&"hold"] = true
		&"climb":
			p[&"lift_f"] = 9.0 if f < 2 else 0.0
			p[&"lift_b"] = 0.0 if f < 2 else 9.0
			p[&"leg_f"] = 0.25 if f < 2 else 0.0
			p[&"leg_b"] = 0.0 if f < 2 else 0.25
			p[&"arm_f"] = [2.7, 2.9, 3.05, 2.85][f]
			p[&"arm_b"] = [3.05, 2.85, 2.7, 2.9][f]
			p[&"bob"] = -2.0 if f % 2 == 1 else 0.0
		&"dig":
			p[&"arm_f"] = [3.0, 2.4, 1.5, 0.95][f]
			p[&"arm_b"] = float(p[&"arm_f"]) - 0.3
			p[&"leg_f"] = 0.2
			p[&"leg_b"] = -0.15
			p[&"bob"] = 2.0 if f == 3 else 0.0
			p[&"tool"] = true
	return p


## Builds the rig under `root` (children in draw order). Returns part map.
## Parts start as vector drawings; use_atlas() switches them to a baked
## texture (one batched textured rect per part).
static func build(root: Node2D, look: Dictionary) -> Dictionary:
	var parts := {}
	for part_name in [&"shadow", &"arm_b", &"leg_b", &"leg_f", &"torso", &"head"]:
		parts[part_name] = _part(root, painter(part_name, look))
	parts[&"carry"] = _part(root, func(ci: Part) -> void: draw_chunk(ci, CARRY_AT, 13.0, ci.tint, 7))
	parts[&"arm_f"] = _part(root, painter(&"arm_f", look))
	var pick := _part(parts[&"arm_f"], painter(&"pickaxe", look))
	pick.show_behind_parent = true
	parts[&"pickaxe"] = pick
	apply_pose(parts, &"idle", 0, NO_CARRY)
	return parts


## Vector painter of one part in part-local space (pivot at the origin).
static func painter(part_name: StringName, look: Dictionary) -> Callable:
	var sleeve: Color = look[&"sleeve"]
	var skin: Color = look[&"skin"]
	var pants: Color = look[&"pants"]
	match part_name:
		&"shadow":
			return func(ci: CanvasItem) -> void: _ellipse(ci, Vector2(0, -2), Vector2(24, 5), P.SHADOW)
		&"arm_b":
			return func(ci: CanvasItem) -> void: _arm(ci, sleeve.darkened(0.25), skin.darkened(0.2))
		&"arm_f":
			return func(ci: CanvasItem) -> void: _arm(ci, sleeve, skin)
		&"leg_b":
			return func(ci: CanvasItem) -> void: _leg(ci, pants.darkened(0.25))
		&"leg_f":
			return func(ci: CanvasItem) -> void: _leg(ci, pants)
		&"torso":
			return func(ci: CanvasItem) -> void: _torso(ci, look)
		&"head":
			return func(ci: Part) -> void: _head(ci, look, Vector2(2, -116), ci.blink)
		&"head_blink":
			return func(ci: CanvasItem) -> void: _head(ci, look, Vector2(2, -116), true)
		&"pickaxe":
			return func(ci: CanvasItem) -> void: _pickaxe(ci)
	return func(_ci: CanvasItem) -> void: pass


# --- Baked atlas ------------------------------------------------------------
## Each baked part: [bounds in part-local space, slot origin in the atlas].
## Bounds include the outline; slots do not overlap (2 px gutters).
const ATLAS_SIZE := Vector2i(300, 124)
const SLOTS := {
	&"head": [Rect2(-38, -184, 84, 106), Vector2(0, 0)],
	&"head_blink": [Rect2(-38, -184, 84, 106), Vector2(86, 0)],
	&"torso": [Rect2(-23, -87, 46, 68), Vector2(172, 0)],
	&"arm_b": [Rect2(-9, -9, 18, 42), Vector2(220, 0)],
	&"arm_f": [Rect2(-9, -9, 18, 42), Vector2(240, 0)],
	&"pickaxe": [Rect2(-19, 13, 38, 41), Vector2(260, 0)],
	&"leg_b": [Rect2(-11, -10, 26, 48), Vector2(172, 72)],
	&"leg_f": [Rect2(-11, -10, 26, 48), Vector2(200, 72)],
	&"shadow": [Rect2(-26, -8, 52, 12), Vector2(0, 110)],
}


## Adds every part's vector drawing to `vp` at its atlas slot (to render once).
static func populate_bake(vp: Node, look: Dictionary) -> void:
	for part_name in SLOTS:
		var b: Rect2 = SLOTS[part_name][0]
		var p := _part(vp, painter(part_name, look))
		p.position = (SLOTS[part_name][1] as Vector2) - b.position


## Switches rig parts to draw their region of a baked atlas texture.
static func use_atlas(parts: Dictionary, atlas: Texture2D) -> void:
	for part_name in parts:
		if not SLOTS.has(part_name):
			continue  # carry chunk stays vector (tinted per material)
		var b: Rect2 = SLOTS[part_name][0]
		var src := Rect2(SLOTS[part_name][1], b.size)
		var part: Part = parts[part_name]
		if part_name == &"head":
			var blink_src := Rect2(SLOTS[&"head_blink"][1], b.size)
			part.painter = func(ci: Part) -> void: ci.draw_texture_rect_region(atlas, b, blink_src if ci.blink else src)
		else:
			part.painter = func(ci: CanvasItem) -> void: ci.draw_texture_rect_region(atlas, b, src)
		part.queue_redraw()


## Moves the parts to a frame's pose. `carry` alpha 0 hides the held item.
static func apply_pose(parts: Dictionary, anim: StringName, frame: int, carry: Color) -> void:
	var p := pose(anim, frame)
	var up := Vector2(0, p[&"bob"])
	var arm_b: Node2D = parts[&"arm_b"]
	var arm_f: Node2D = parts[&"arm_f"]
	var leg_b: Node2D = parts[&"leg_b"]
	var leg_f: Node2D = parts[&"leg_f"]
	arm_b.position = SHOULDER_B + up
	arm_b.rotation = -float(p[&"arm_b"])
	arm_f.position = SHOULDER_F + up
	arm_f.rotation = -float(p[&"arm_f"])
	leg_b.position = HIP_B - Vector2(0, p[&"lift_b"])
	leg_b.rotation = -float(p[&"leg_b"])
	leg_f.position = HIP_F - Vector2(0, p[&"lift_f"])
	leg_f.rotation = -float(p[&"leg_f"])
	(parts[&"torso"] as Node2D).position = up
	var head: Part = parts[&"head"]
	head.position = up
	head.blink = p[&"blink"]
	var carry_part: Part = parts[&"carry"]
	carry_part.visible = p[&"hold"] and carry.a > 0.0
	if carry_part.visible:
		carry_part.position = up
		carry_part.tint = carry
	(parts[&"pickaxe"] as Node2D).visible = p[&"tool"]


## Rounded rock/ore chunk (carried items and ground piles).
static func draw_chunk(ci: CanvasItem, c: Vector2, r: float, col: Color, s: int) -> void:
	var pts := PackedVector2Array()
	var outline := PackedVector2Array()
	for i in 8:
		var a := TAU * i / 8.0
		var k := 0.8 + 0.25 * PixelCanvas.hash01(i, s, 77)
		var d := Vector2(cos(a), sin(a) * 0.8) * r * k
		pts.append(c + d)
		outline.append(c + d + d.normalized() * 2.5)
	ci.draw_colored_polygon(outline, P.OUTLINE)
	ci.draw_colored_polygon(pts, col)
	ci.draw_circle(c + Vector2(-r * 0.3, -r * 0.3), r * 0.32, col.lightened(0.35))
	ci.draw_circle(c + Vector2(r * 0.25, r * 0.3), r * 0.25, col.darkened(0.25))


# --- Parts --------------------------------------------------------------------

static func _part(parent: Node, painter: Callable) -> Part:
	var p := Part.new()
	p.painter = painter
	parent.add_child(p)
	return p


static func _ellipse(ci: CanvasItem, c: Vector2, r: Vector2, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 16:
		var a := TAU * i / 16.0
		pts.append(c + Vector2(cos(a) * r.x, sin(a) * r.y))
	ci.draw_colored_polygon(pts, col)


static func _rrect(ci: CanvasItem, r: Rect2, rad: float, col: Color) -> void:
	rad = minf(rad, minf(r.size.x, r.size.y) / 2.0)
	ci.draw_rect(Rect2(r.position + Vector2(rad, 0), r.size - Vector2(2 * rad, 0)), col)
	ci.draw_rect(Rect2(r.position + Vector2(0, rad), r.size - Vector2(0, 2 * rad)), col)
	for c in [r.position + Vector2(rad, rad), Vector2(r.end.x - rad, r.position.y + rad),
			Vector2(r.position.x + rad, r.end.y - rad), r.end - Vector2(rad, rad)]:
		ci.draw_circle(c, rad, col)


static func _rrect_outlined(ci: CanvasItem, r: Rect2, rad: float, col: Color) -> void:
	_rrect(ci, r.grow(OUTLINE_W), rad + OUTLINE_W, P.OUTLINE)
	_rrect(ci, r, rad, col)


static func _limb(ci: CanvasItem, a: Vector2, b: Vector2, w: float, col: Color) -> void:
	ci.draw_line(a, b, P.OUTLINE, w + 2.0 * OUTLINE_W)
	ci.draw_circle(a, w / 2.0 + OUTLINE_W, P.OUTLINE)
	ci.draw_circle(b, w / 2.0 + OUTLINE_W, P.OUTLINE)
	ci.draw_line(a, b, col, w)
	ci.draw_circle(a, w / 2.0, col)
	ci.draw_circle(b, w / 2.0, col)


## Arm hanging down from the shoulder pivot (0, 0): sleeve, then hand.
static func _arm(ci: CanvasItem, sleeve: Color, skin: Color) -> void:
	var elbow := Vector2(0, ARM_LEN * 0.55)
	var hand := Vector2(0, ARM_LEN)
	_limb(ci, Vector2.ZERO, elbow, 10.0, sleeve)
	_limb(ci, elbow, hand, 8.0, skin)


## Leg hanging down from the hip pivot (0, 0), boot pointing forward.
static func _leg(ci: CanvasItem, pants: Color) -> void:
	var foot := Vector2(0, LEG_LEN)
	_limb(ci, Vector2.ZERO, foot + Vector2(0, -2), 12.0, pants)
	_rrect_outlined(ci, Rect2(foot + Vector2(-7, -6), Vector2(18, 11)), 4.0, P.BOOT)
	ci.draw_rect(Rect2(foot + Vector2(-7, 3), Vector2(18, 2)), P.BOOT.darkened(0.4))


static func _torso(ci: CanvasItem, look: Dictionary) -> void:
	var role: StringName = look[&"role"]
	var top := -82.0
	var shirt: Color = look[&"shirt"]
	if role == &"scientist":
		# Long lab coat over a coloured shirt.
		_rrect_outlined(ci, Rect2(-18, top, 36, 58), 9.0, P.COAT_WHITE)
		ci.draw_colored_polygon(PackedVector2Array([Vector2(-6, top + 1), Vector2(6, top + 1), Vector2(0, top + 20)]), look[&"accent"])
		ci.draw_line(Vector2(0, top + 20), Vector2(0, top + 56), Color(0.6, 0.62, 0.65), 2.0)
		ci.draw_rect(Rect2(6, top + 28, 8, 7), Color(0.75, 0.78, 0.8))
		return
	_rrect_outlined(ci, Rect2(-17, top, 34, 46), 10.0, shirt)
	match role:
		&"miner":
			# Hi-vis vest straps with reflective bands.
			for x in [-11.0, 5.0]:
				ci.draw_rect(Rect2(x, top + 2, 7, 38), P.SAFETY_ORANGE)
				ci.draw_rect(Rect2(x, top + 20, 7, 4), P.DUST_BEIGE)
		&"technician":
			ci.draw_rect(Rect2(-17, top + 8, 34, 3), shirt.lightened(0.25))
			ci.draw_rect(Rect2(4, top + 14, 9, 8), shirt.darkened(0.25))
		&"cook":
			ci.draw_colored_polygon(PackedVector2Array([Vector2(-10, top), Vector2(10, top), Vector2(0, top + 12)]), look[&"accent"])
			for y in [top + 16, top + 26]:
				ci.draw_circle(Vector2(-6, y), 2.0, Color(0.7, 0.7, 0.7))
				ci.draw_circle(Vector2(6, y), 2.0, Color(0.7, 0.7, 0.7))
	# Belt.
	ci.draw_rect(Rect2(-17, top + 38, 34, 6), P.LEATHER_BROWN.darkened(0.3))
	ci.draw_rect(Rect2(-3, top + 38, 6, 6), P.HELMET_YELLOW.darkened(0.2))


static func _head(ci: CanvasItem, look: Dictionary, hc: Vector2, blink: bool) -> void:
	var role: StringName = look[&"role"]
	var skin: Color = look[&"skin"]
	var hair: Color = look[&"hair"]
	# Hair mass with outline, ear, face.
	ci.draw_circle(hc, HEAD_R + OUTLINE_W, P.OUTLINE)
	ci.draw_circle(hc, HEAD_R, hair)
	ci.draw_circle(hc + Vector2(-15, 6), 7.0 + OUTLINE_W, P.OUTLINE)
	ci.draw_circle(hc + Vector2(-15, 6), 7.0, skin.darkened(0.08))
	ci.draw_circle(hc + Vector2(5, 6), 23.0, skin)
	# Fringe.
	for i in 4:
		ci.draw_circle(hc + Vector2(-8 + i * 8, -14 + absf(i - 1.5) * 2.0), 8.5, hair)
	# Eyes (closed while blinking), blush, mouth.
	var eye_y := hc.y + 6.0
	for ex in [hc.x - 2.0, hc.x + 13.0]:
		if blink:
			ci.draw_line(Vector2(ex - 3.5, eye_y + 1), Vector2(ex + 3.5, eye_y + 1), P.EYE, 2.0)
		else:
			_ellipse(ci, Vector2(ex, eye_y), Vector2(3.6, 5.2), P.EYE)
			ci.draw_circle(Vector2(ex + 1.2, eye_y - 2.0), 1.6, Color.WHITE)
	ci.draw_circle(hc + Vector2(-8, 15), 3.5, P.BLUSH)
	ci.draw_circle(hc + Vector2(21, 15), 3.5, P.BLUSH)
	ci.draw_arc(hc + Vector2(6, 15), 3.5, 0.3, PI - 0.3, 6, P.EYE, 1.8)
	match role:
		&"miner":
			_helmet(ci, hc, P.HELMET_YELLOW, true)
		&"technician":
			_helmet(ci, hc, P.SAFETY_ORANGE, false)
		&"scientist":
			for ex in [hc.x - 2.0, hc.x + 13.0]:
				ci.draw_arc(Vector2(ex, eye_y), 6.5, 0.0, TAU, 14, P.OUTLINE, 2.0)
			ci.draw_line(Vector2(hc.x + 4.5, eye_y), Vector2(hc.x + 6.5, eye_y), P.OUTLINE, 2.0)
		&"cook":
			_chef_hat(ci, hc)


static func _dome(c: Vector2, r: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 13:
		var a := PI + PI * i / 12.0
		pts.append(c + Vector2(cos(a) * r, sin(a) * r))
	return pts


static func _helmet(ci: CanvasItem, hc: Vector2, col: Color, lamp: bool) -> void:
	var c := hc + Vector2(1, -6)
	ci.draw_colored_polygon(_dome(c, 33.0 + OUTLINE_W), P.OUTLINE)
	ci.draw_colored_polygon(_dome(c, 33.0), col)
	ci.draw_colored_polygon(_dome(c + Vector2(-6, -4), 20.0), col.lightened(0.22))
	_rrect_outlined(ci, Rect2(c + Vector2(-34, -4), Vector2(74, 8)), 4.0, col.darkened(0.15))
	ci.draw_rect(Rect2(c + Vector2(-32, -12), Vector2(64, 6)), P.CHARCOAL)
	if lamp:
		var lc := c + Vector2(22, -13)
		ci.draw_circle(lc, 15.0, Color(P.LAMP, 0.22))
		ci.draw_circle(lc, 7.0 + OUTLINE_W, P.OUTLINE)
		ci.draw_circle(lc, 7.0, Color("#9a9a9a"))
		ci.draw_circle(lc + Vector2(1, 0), 5.0, P.LAMP)
	else:
		# Goggles resting on the band.
		for gx in [6.0, 20.0]:
			ci.draw_circle(c + Vector2(gx, -9), 6.0 + OUTLINE_W, P.OUTLINE)
			ci.draw_circle(c + Vector2(gx, -9), 6.0, P.SKY_BLUE)
			ci.draw_circle(c + Vector2(gx - 2, -11), 2.0, Color(1, 1, 1, 0.8))


static func _chef_hat(ci: CanvasItem, hc: Vector2) -> void:
	var puffs := [Vector2(-13, -40), Vector2(1, -47), Vector2(15, -40)]
	for p in puffs:
		ci.draw_circle(hc + p, 14.0 + OUTLINE_W, P.OUTLINE)
	_rrect_outlined(ci, Rect2(hc + Vector2(-22, -34), Vector2(46, 16)), 4.0, P.COAT_WHITE)
	for p in puffs:
		ci.draw_circle(hc + p, 14.0, P.COAT_WHITE)
	ci.draw_rect(Rect2(hc + Vector2(-22, -34), Vector2(46, 16)), P.COAT_WHITE)
	ci.draw_line(hc + Vector2(-22, -24), hc + Vector2(24, -24), Color(0.8, 0.8, 0.82), 2.0)


## Pickaxe held in the front hand (arm-local space, arm hangs along +y).
static func _pickaxe(ci: CanvasItem) -> void:
	var hand := Vector2(0, ARM_LEN)
	var end := hand + Vector2(0, 22)
	var head := PackedVector2Array([end + Vector2(-14, -4), end + Vector2(0, 2), end + Vector2(14, -4)])
	ci.draw_line(hand - Vector2(0, 6), end, P.OUTLINE, 7.0)
	ci.draw_line(hand - Vector2(0, 6), end, P.WOOD, 3.5)
	ci.draw_polyline(head, P.OUTLINE, 7.0)
	ci.draw_polyline(head, Color("#a8acb2"), 3.5)
