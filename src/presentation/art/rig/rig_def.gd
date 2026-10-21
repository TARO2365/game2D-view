class_name RigDef
extends RefCounted
## Cut-out rig definition (D-027 step 3): one atlas texture + parts. Each part
## has an atlas region, a pivot (joint) inside that region and a "joint"
## position in assembled cell space (128x192 cell, origin top-left, feet
## bottom-centre at (64, 192)); a bone's rest offset is its joint minus its
## parent's joint. Bones without a part (e.g. a pilot without forearms) are
## simply absent; RigFigure and RigAnim skip them.
##
## Sources, best first:
## 1. rig/rig_<role>.png + rig/rig_<role>.json — the owner's parts sheet,
##    sliced by tools/art_import.gd (PROMPTS_V2_RIG.md).
## 2. Pilot: parts cut automatically from the role's idle sheet (head,
##    torso, both arms, both legs; blink head from the blink frame).
## Modular citizens: parts are looked up per slot, so a citizen can combine
## a shared body with another head/hair/hat/outfit atlas later (overrides).

const CELL := Vector2(128, 192)
const FEET := Vector2(64, 192)

## Parent of each bone; "" = root (feet pivot).
const PARENT := {
	&"pelvis": &"", &"torso": &"pelvis", &"head": &"torso", &"hair": &"head", &"helmet": &"head",
	&"upper_arm_b": &"torso", &"forearm_b": &"upper_arm_b", &"hand_b": &"forearm_b",
	&"upper_arm_f": &"torso", &"forearm_f": &"upper_arm_f", &"hand_f": &"forearm_f",
	&"thigh_b": &"pelvis", &"shin_b": &"thigh_b", &"boot_b": &"shin_b",
	&"thigh_f": &"pelvis", &"shin_f": &"thigh_f", &"boot_f": &"shin_f",
	&"prop": &"hand_f", &"carry": &"torso",
}
## Back-to-front draw order.
const ORDER: Array[StringName] = [
	&"upper_arm_b", &"forearm_b", &"hand_b",
	&"thigh_b", &"shin_b", &"boot_b",
	&"thigh_f", &"shin_f", &"boot_f",
	&"pelvis", &"torso", &"carry",
	&"hair", &"head", &"helmet",
	&"prop", &"upper_arm_f", &"forearm_f", &"hand_f",
]

var role: StringName = &""
var source := ""
var atlas: Texture2D
## name -> {region: Rect2, pivot: Vector2, joint: Vector2}
var parts: Dictionary = {}
## Optional blink variant of the head (same size/pivot), or Rect2() if none.
var head_blink := Rect2()

static var _cache: Dictionary = {}


static func for_role(role: StringName) -> RigDef:
	var key := "%s|%s" % [ArtLibrary.base_dir, role]
	if not _cache.has(key):
		var d := from_files(role)
		if d == null:
			d = pilot_from_sheet(role)
		_cache[key] = d
	return _cache[key]


static func clear_cache() -> void:
	_cache.clear()


func has_part(name: StringName) -> bool:
	return parts.has(name)


## Joint of a bone in cell space; virtual bones (no part) inherit a sensible
## position: pelvis from the thighs, prop / carry from the front arm.
func joint(name: StringName) -> Vector2:
	if parts.has(name):
		return parts[name].joint
	match name:
		&"pelvis":
			if parts.has(&"thigh_f") and parts.has(&"thigh_b"):
				return ((parts[&"thigh_f"].joint as Vector2) + (parts[&"thigh_b"].joint as Vector2)) / 2.0
		&"carry":
			return joint(&"torso") + Vector2(18, -38)
	return FEET


## Rest offset of a bone from its parent's joint.
func rest_offset(name: StringName) -> Vector2:
	var parent: StringName = PARENT.get(name, &"")
	while parent != &"" and not parts.has(parent) and parent != &"pelvis":
		parent = PARENT.get(parent, &"")
	var base := FEET if parent == &"" else joint(parent)
	return joint(name) - base


## Actual parent used at runtime (skips bones the rig does not have).
func parent_of(name: StringName) -> StringName:
	var parent: StringName = PARENT.get(name, &"")
	while parent != &"" and not parts.has(parent) and parent != &"pelvis":
		parent = PARENT.get(parent, &"")
	return parent


# --- Owner parts sheet ----------------------------------------------------------

static func from_files(role: StringName) -> RigDef:
	var tex := ArtLibrary.texture("rig/rig_%s.png" % role)
	var path := ArtLibrary.base_dir.path_join("rig/rig_%s.json" % role)
	if tex == null or not FileAccess.file_exists(path):
		return null
	var json: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (json is Dictionary) or not (json as Dictionary).has("parts"):
		return null
	var d := RigDef.new()
	d.role = role
	d.source = "parts"
	d.atlas = tex
	for name in json["parts"]:
		var p: Dictionary = json["parts"][name]
		var r: Array = p["rect"]
		d.parts[StringName(name)] = {
			"region": Rect2(r[0], r[1], r[2], r[3]),
			"pivot": Vector2(p["pivot"][0], p["pivot"][1]),
			"joint": Vector2(p["joint"][0], p["joint"][1]),
		}
	if json.has("head_blink"):
		var b: Array = json["head_blink"]
		d.head_blink = Rect2(b[0], b[1], b[2], b[3])
	return d


# --- Pilot: auto-cut from the idle sheet -----------------------------------------

## Cuts head / torso / arms / legs out of the first idle frame (blink head
## from the blink frame). Exclusive pixel ownership plus small overlaps at
## the joints. Null when the role has no idle (or walk) sheet.
static func pilot_from_sheet(role: StringName) -> RigDef:
	var img := ArtLibrary.image(ArtLibrary.npc_sheet_path(role, &"idle"))
	var blink_frame := 1
	if img == null:
		img = ArtLibrary.image(ArtLibrary.npc_sheet_path(role, &"walk"))
		blink_frame = -1
	if img == null:
		return null
	var cw := ArtLibrary.NPC_CELL.x
	var frame := img.get_region(Rect2i(0, 0, cw, ArtLibrary.NPC_CELL.y))
	var blink: Image = null
	if blink_frame > 0 and img.get_width() >= cw * 2:
		blink = img.get_region(Rect2i(cw * blink_frame, 0, cw, ArtLibrary.NPC_CELL.y))
	var bb := frame.get_used_rect()
	if bb.size.y < 40:
		return null
	var t := float(bb.position.y)
	var h := float(bb.size.y)
	var x0 := float(bb.position.x)
	var x1 := float(bb.end.x)
	var w := x1 - x0
	var cx := _torso_centre(frame, int(t + 0.55 * h), int(t + 0.7 * h))
	var neck := roundi(t + 0.42 * h)
	var hip := roundi(t + 0.76 * h)
	var arm_top := neck + 2
	var arm_bot := roundi(t + 0.86 * h)
	# Arms: the strips left / right of the torso core (core = cx +- 0.2 w).
	var core0 := roundi(cx - 0.2 * w)
	var core1 := roundi(cx + 0.2 * w)
	var rects := {
		&"head": Rect2i(int(x0), int(t), int(w), neck + 5 - int(t)),
		&"torso": Rect2i(core0, neck - 3, core1 - core0, hip + 6 - (neck - 3)),
		&"upper_arm_b": Rect2i(int(x0), arm_top, core0 + 3 - int(x0), arm_bot - arm_top),
		&"upper_arm_f": Rect2i(core1 - 3, arm_top, int(x1) - core1 + 3, arm_bot - arm_top),
		&"thigh_b": Rect2i(core0 - 4, hip - 6, roundi(cx) + 3 - (core0 - 4), int(bb.end.y) - (hip - 6)),
		&"thigh_f": Rect2i(roundi(cx) - 3, hip - 6, core1 + 4 - (roundi(cx) - 3), int(bb.end.y) - (hip - 6)),
	}
	var joints := {
		&"head": Vector2(cx, neck),
		&"torso": Vector2(cx, hip),
		&"upper_arm_b": Vector2(core0 - 1, neck + 0.06 * h),
		&"upper_arm_f": Vector2(core1 + 1, neck + 0.06 * h),
		&"thigh_b": Vector2(cx - 0.1 * w, hip),
		&"thigh_f": Vector2(cx + 0.1 * w, hip),
	}
	# Exclusive ownership outside the overlap bands: arms own their strips in
	# the arm rows, the head owns rows above the neck, legs below the hip.
	var owner := func(px: int, py: int) -> StringName:
		if py < neck:
			return &"head"
		if py >= arm_top and py < arm_bot and px < core0:
			return &"upper_arm_b"
		if py >= arm_top and py < arm_bot and px >= core1:
			return &"upper_arm_f"
		if py >= hip:
			return &"thigh_b" if px < cx else &"thigh_f"
		return &"torso"
	var names: Array[StringName] = [&"head", &"torso", &"upper_arm_b", &"upper_arm_f", &"thigh_b", &"thigh_f"]
	var overlap := {&"head": 5, &"torso": 6, &"upper_arm_b": 3, &"upper_arm_f": 3, &"thigh_b": 6, &"thigh_f": 6}
	var atlas_w := 0
	var atlas_h := 0
	for n in names:
		var r: Rect2i = (rects[n] as Rect2i).intersection(Rect2i(Vector2i.ZERO, frame.get_size()))
		rects[n] = r
		atlas_w += r.size.x + 2
		atlas_h = maxi(atlas_h, r.size.y)
	var head_r: Rect2i = rects[&"head"]
	if blink:
		atlas_w += head_r.size.x + 2
	var atlas_img := Image.create(maxi(atlas_w, 1), maxi(atlas_h, 1), false, Image.FORMAT_RGBA8)
	var d := RigDef.new()
	d.role = role
	d.source = "pilot"
	var ax := 0
	for n in names:
		var r: Rect2i = rects[n]
		var m: int = overlap[n]
		for y in r.size.y:
			for x in r.size.x:
				var px := r.position.x + x
				var py := r.position.y + y
				var o: StringName = owner.call(px, py)
				var keep := o == n
				if not keep:
					# Overlap band: copy pixels within m px of the part's own area.
					for k in range(1, m + 1):
						if owner.call(px, py + k) == n or owner.call(px, py - k) == n \
								or owner.call(px + k, py) == n or owner.call(px - k, py) == n:
							keep = true
							break
				if keep:
					atlas_img.set_pixel(ax + x, y, frame.get_pixel(px, py))
		var jt: Vector2 = joints[n]
		d.parts[n] = {"region": Rect2(ax, 0, r.size.x, r.size.y), "pivot": jt - Vector2(r.position), "joint": jt}
		ax += r.size.x + 2
	if blink:
		for y in head_r.size.y:
			for x in head_r.size.x:
				var py := head_r.position.y + y
				if py < neck + 5:
					atlas_img.set_pixel(ax + x, y, blink.get_pixel(head_r.position.x + x, py))
		d.head_blink = Rect2(ax, 0, head_r.size.x, head_r.size.y)
	d.atlas = ImageTexture.create_from_image(atlas_img)
	return d


static func _torso_centre(img: Image, y0: int, y1: int) -> float:
	var xs: Array[int] = []
	for y in range(y0, y1):
		for x in img.get_width():
			if img.get_pixel(x, y).a > 0.5:
				xs.append(x)
	if xs.is_empty():
		return img.get_width() / 2.0
	xs.sort()
	return float(xs[xs.size() / 2])
