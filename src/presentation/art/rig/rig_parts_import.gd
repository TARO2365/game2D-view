class_name RigPartsImport
extends RefCounted
## Slices an owner "character parts sheet" (PROMPTS_V2_RIG.md §1) into a rig
## atlas + JSON (RigDef.from_files). Used by tools/art_import.gd; pure image
## code so it is unit-testable.
##
## The sheet shows separated parts in four rows (reading order):
##   row 1: head, helmet, torso, pelvis
##   row 2: upper_arm_b, forearm_b, hand_b, upper_arm_f, forearm_f, hand_f
##   row 3: thigh_b, shin_b, boot_b, thigh_f, shin_f, boot_f
##   row 4: prop, head_blink
## Parts are found as opaque blobs (dust removed), grouped into rows by their
## vertical centres, ordered left to right, then scaled by one factor so the
## assembled character is CHAR_HEIGHT tall, and placed on a standard skeleton.

const LAYOUT: Array = [
	[&"head", &"helmet", &"torso", &"pelvis"],
	[&"upper_arm_b", &"forearm_b", &"hand_b", &"upper_arm_f", &"forearm_f", &"hand_f"],
	[&"thigh_b", &"shin_b", &"boot_b", &"thigh_f", &"shin_f", &"boot_f"],
	[&"prop", &"head_blink"],
]
## Assembled height (head top to soles) in cell px (matches the sheets).
const CHAR_HEIGHT := 150.0
## Joint overlap: each limb segment hides this fraction of its length under
## the previous one (the prompt asks for rounded overlapping joint ends).
const OVERLAP := 0.12
const ALPHA := 128


## Returns {"image": Image atlas, "json": Dictionary} or {"error": String}.
static func slice(sheet: Image) -> Dictionary:
	var img := sheet.duplicate() as Image
	img.convert(Image.FORMAT_RGBA8)
	var blobs := _blobs(img)
	var rows := _rows(blobs)
	if rows.size() != LAYOUT.size():
		return {"error": "expected %d rows of parts, found %d" % [LAYOUT.size(), rows.size()]}
	var found := {}
	for r in rows.size():
		var row: Array = rows[r]
		var names: Array = LAYOUT[r]
		if row.size() != names.size():
			return {"error": "row %d: expected %d parts, found %d" % [r + 1, names.size(), row.size()]}
		for i in row.size():
			found[names[i]] = row[i]
	# One scale for all parts: head + torso + thigh + shin + boot heights
	# (minus overlaps) = CHAR_HEIGHT.
	var stack := 0.0
	for n in [&"head", &"torso", &"thigh_f", &"shin_f", &"boot_f"]:
		var h := float((found[n] as Rect2i).size.y)
		stack += h * (1.0 - OVERLAP) if n != &"head" else h
	var s := CHAR_HEIGHT / maxf(stack, 1.0)
	# Pack scaled parts into one atlas row.
	var regions := {}
	var images := {}
	var aw := 0
	var ah := 0
	for n in found:
		var r: Rect2i = found[n]
		var part := img.get_region(r)
		part.resize(maxi(1, roundi(r.size.x * s)), maxi(1, roundi(r.size.y * s)), Image.INTERPOLATE_LANCZOS)
		images[n] = part
		regions[n] = Rect2i(aw, 0, part.get_width(), part.get_height())
		aw += part.get_width() + 2
		ah = maxi(ah, part.get_height())
	var atlas := Image.create(maxi(aw, 1), maxi(ah, 1), false, Image.FORMAT_RGBA8)
	for n in images:
		var p: Image = images[n]
		atlas.blit_rect(p, Rect2i(Vector2i.ZERO, p.get_size()), (regions[n] as Rect2i).position)
	# Skeleton (cell space, feet bottom-centre at (64, 192)).
	var size := func(n: StringName) -> Vector2: return Vector2((regions[n] as Rect2i).size)
	var ov := func(n: StringName) -> float: return (size.call(n) as Vector2).y * OVERLAP
	var foot_y := 192.0
	var boot_h: float = (size.call(&"boot_f") as Vector2).y
	var shin_h: float = (size.call(&"shin_f") as Vector2).y
	var thigh_h: float = (size.call(&"thigh_f") as Vector2).y
	var ankle: float = foot_y - boot_h + ov.call(&"boot_f")
	var knee: float = ankle - shin_h + ov.call(&"shin_f")
	var hip: float = knee - thigh_h + ov.call(&"thigh_f")
	var torso_h: float = (size.call(&"torso") as Vector2).y
	var neck: float = hip - torso_h * (1.0 - OVERLAP)
	var torso_w: float = (size.call(&"torso") as Vector2).x
	var head_h: float = (size.call(&"head") as Vector2).y
	var parts := {}
	var top_pivot := func(n: StringName) -> Vector2: return Vector2((size.call(n) as Vector2).x / 2.0, ov.call(n) * 0.5)
	var bottom_pivot := func(n: StringName) -> Vector2: return Vector2((size.call(n) as Vector2).x / 2.0, (size.call(n) as Vector2).y)
	var add := func(n: StringName, pivot: Vector2, joint: Vector2) -> void:
		var rg: Rect2i = regions[n]
		parts[n] = {"rect": [rg.position.x, rg.position.y, rg.size.x, rg.size.y], "pivot": [pivot.x, pivot.y], "joint": [joint.x, joint.y]}
	add.call(&"pelvis", top_pivot.call(&"pelvis"), Vector2(64, hip))
	add.call(&"torso", bottom_pivot.call(&"torso"), Vector2(64, hip + torso_h * OVERLAP))
	add.call(&"head", bottom_pivot.call(&"head"), Vector2(66, neck + head_h * 0.08))
	add.call(&"helmet", Vector2((size.call(&"helmet") as Vector2).x / 2.0, (size.call(&"helmet") as Vector2).y),
			Vector2(66, neck - head_h * 0.45))
	for side in [["b", -0.36], ["f", 0.36]]:
		var sx: float = 64.0 + float(side[1]) * torso_w
		var ua := StringName("upper_arm_" + side[0])
		var fa := StringName("forearm_" + side[0])
		var hd := StringName("hand_" + side[0])
		var shoulder := Vector2(sx, neck + torso_h * 0.12)
		var elbow: Vector2 = shoulder + Vector2(0, (size.call(ua) as Vector2).y - ov.call(ua))
		var wrist: Vector2 = elbow + Vector2(0, (size.call(fa) as Vector2).y - ov.call(fa))
		add.call(ua, top_pivot.call(ua), shoulder)
		add.call(fa, top_pivot.call(fa), elbow)
		add.call(hd, top_pivot.call(hd), wrist)
		var lx: float = 64.0 + float(side[1]) * 0.5 * torso_w
		var th := StringName("thigh_" + side[0])
		var sh := StringName("shin_" + side[0])
		var bt := StringName("boot_" + side[0])
		add.call(th, top_pivot.call(th), Vector2(lx, hip))
		add.call(sh, top_pivot.call(sh), Vector2(lx, knee))
		add.call(bt, top_pivot.call(bt), Vector2(lx, ankle))
	# Pickaxe: held at 80 % down its handle.
	var ps: Vector2 = size.call(&"prop")
	var wrist_f: Array = parts[&"hand_f"]["joint"]
	add.call(&"prop", Vector2(ps.x * 0.5, ps.y * 0.8), Vector2(wrist_f[0], wrist_f[1] + 6.0))
	var json := {"version": 1, "char_height": CHAR_HEIGHT, "parts": {}}
	for n in parts:
		json["parts"][String(n)] = parts[n]
	var hb: Rect2i = regions[&"head_blink"]
	json["head_blink"] = [hb.position.x, hb.position.y, hb.size.x, hb.size.y]
	return {"image": atlas, "json": json}


## Opaque blobs (8-connected on a 1/4 copy for speed), dust removed.
static func _blobs(img: Image) -> Array[Rect2i]:
	var q := 4
	var sm := img.duplicate() as Image
	sm.resize(maxi(1, img.get_width() / q), maxi(1, img.get_height() / q), Image.INTERPOLATE_BILINEAR)
	var w := sm.get_width()
	var h := sm.get_height()
	var d := sm.get_data()
	var label := PackedInt32Array()
	label.resize(w * h)
	label.fill(-1)
	var boxes: Array[Rect2i] = []
	var sizes: Array[int] = []
	for start in w * h:
		if label[start] != -1 or d[start * 4 + 3] < ALPHA:
			continue
		var id := boxes.size()
		var box := Rect2i(start % w, start / w, 1, 1)
		var count := 0
		var stack: Array[int] = [start]
		label[start] = id
		while not stack.is_empty():
			var p: int = stack.pop_back()
			var px := p % w
			var py := p / w
			count += 1
			box = box.expand(Vector2i(px + 1, py + 1)).expand(Vector2i(px, py))
			for dy in [-1, 0, 1]:
				for dx in [-1, 0, 1]:
					var x: int = px + dx
					var y: int = py + dy
					if x < 0 or y < 0 or x >= w or y >= h:
						continue
					var qi := y * w + x
					if label[qi] == -1 and d[qi * 4 + 3] >= ALPHA:
						label[qi] = id
						stack.append(qi)
		boxes.append(box)
		sizes.append(count)
	var out: Array[Rect2i] = []
	if sizes.is_empty():
		return out
	var largest: int = sizes.max()
	for i in boxes.size():
		if sizes[i] >= maxi(6, roundi(largest * 0.01)):
			var b := boxes[i]
			out.append(Rect2i(b.position * q, b.size * q).grow(q).intersection(Rect2i(Vector2i.ZERO, img.get_size())))
	return out


## Groups blobs into rows: blobs whose vertical extents overlap belong to the
## same row (rows are separated by empty horizontal bands); each row sorted by x.
static func _rows(blobs: Array[Rect2i]) -> Array:
	var sorted := blobs.duplicate()
	sorted.sort_custom(func(a: Rect2i, b: Rect2i) -> bool: return a.position.y < b.position.y)
	var rows: Array = []
	var row_end := -1
	for b: Rect2i in sorted:
		# Overlap must be substantial (half of the shorter box) to merge.
		if rows.is_empty() or b.position.y > row_end - mini(b.size.y, 40) / 2:
			rows.append([b])
			row_end = b.end.y
		else:
			(rows[-1] as Array).append(b)
			row_end = maxi(row_end, b.end.y)
	for row: Array in rows:
		row.sort_custom(func(a: Rect2i, b: Rect2i) -> bool: return a.position.x < b.position.x)
	return rows
