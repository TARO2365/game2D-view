extends SceneTree
## Imports the owner's raw AI images (assets/incoming/) into spec-named,
## cleaned production files (assets/production/, docs/art/ASSET_SPEC.md).
## Re-runnable: every run rebuilds the outputs from whatever raw files exist.
##
## Usage:
##   godot --headless --path . -s res://tools/art_import.gd -- [--src DIR] [--dst DIR] [--measure]
## --src defaults to res://assets/incoming (raw files are git-ignored; in a
## worktree pass the main checkout's folder). --measure prints the character
## measurements only.
##
## NPC sheets  npc_<role>_<anim>.png  -> characters/npc_<role>_<anim>.png
##   slice into 1:2 cells by blob centroid -> measure each frame on a small
##   copy (head top = first dense row, feet = last dense row + soles, centre =
##   median x of the torso band, head width) -> scale: walk sheet by height
##   (CHAR_HEIGHT + hat allowance), other sheets of the role by head width ->
##   resample from the original -> feet on the cell bottom, body centred ->
##   clean (drop faint alpha, remove detached specks, fix fringe colours).
## Terrain     terrain_<material>_v1..v4.png -> terrain/terrain_<material>.png
##   (min-error-cut wrap = seamless, shared variant borders, 4-variant strip)
## Backwall    backwall_dug_v1..v4.png -> backgrounds/backwall_dug.png (as terrain)
## Sky         sky_surface.png -> backgrounds/sky_surface.png (540 px tall)
## Ladder      ladder.png -> structures/ladder.png (crop to whole rung periods)
## Sprites     item_*/building_*/icon_*.png -> items/ buildings/ ui/ (trim, fit)
## Flat green backgrounds (#00FF00) are keyed out. Every output gets an
## importer="image" .import stub (ASSET_SPEC §9).

const CELL := Vector2i(128, 192)      # ArtLibrary.NPC_CELL
## Lying animations use a wider cell (ArtLibrary.cell_size).
const WIDE_ANIMS: Array[StringName] = [&"sleep"]
const WIDE_CELL := Vector2i(192, 192)
const TILE := 64
## Head-top-to-feet height in the cell (px). The real top (helmet crown,
## hair tufts) sits a few px higher; tools may reach above it.
const CHAR_HEIGHT := 150.0
## Extra measured height for roles whose hat is part of the measured top
## (keeps the body the same size as the other roles).
const HAT_ALLOWANCE := {&"cook": 22.0}
const MEASURE_H := 256                # analysis copy height
const ALPHA_SOLID := 128
const DENSE_TOP := 0.40               # row coverage (fraction of max) for head top
const DENSE_FEET := 0.10              # row coverage for the feet line
const SPECK_MIN_FRACTION := 0.01      # components smaller than this x largest are removed
const SPECK_MIN_PX := 12
const BUILDING_SIZES := {
	"building_door": Vector2i(64, 192), "building_crate": Vector2i(64, 64),
	"building_bed": Vector2i(128, 64), "building_table": Vector2i(128, 64),
}
const TERRAIN_WORK := 256            # cross-fade resolution
const TERRAIN_BLEND := 0.16           # overlap (fraction of the work tile) for the wrap seam
const HD_SIZE := 512                  # TerrainRenderer.HD_SIZE
const HD_WORK := 608                  # HD_SIZE + wrap overlap
const TERRAIN_BORDER := 0.22         # band shared by all variants (fraction of the tile)

var src_dir := "res://assets/incoming"
var dst_dir := "res://assets/production"
var measure_only := false
var report: Array[String] = []


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		match args[i]:
			"--src":
				src_dir = args[i + 1]
			"--dst":
				dst_dir = args[i + 1]
			"--measure":
				measure_only = true
	var files := DirAccess.get_files_at(src_dir)
	if files.is_empty():
		push_error("No files in %s" % src_dir)
		quit(1)
		return
	var terrain: Dictionary = {}  # material -> Array[path]
	var sheets: Array[Dictionary] = []
	var sky_path := ""
	for f in files:
		var path := src_dir.path_join(f)
		if f.begins_with("npc_") and f.get_extension().to_lower() in ["png", "webp", "jpg", "jpeg"]:
			var info := _analyze_npc(path, f.get_basename())
			if not info.is_empty():
				sheets.append(info)
		elif f.begins_with("terrain_") or f.begins_with("backwall_dug") or f.begins_with("background_wall"):
			var key := f.get_basename().trim_prefix("terrain_").replace("background_wall", "backwall_dug")
			var v := key.rfind("_v")
			if v > 0:
				key = key.substr(0, v)
			if not terrain.has(key):
				terrain[key] = []
			terrain[key].append(path)
		elif measure_only:
			continue
		elif f.get_basename() == "ladder":
			_import_ladder(path)
		elif f.get_basename().begins_with("sky_surface"):
			# sky_surface_v2 (batch 2) wins over sky_surface when both exist.
			if sky_path == "" or f.get_basename() > sky_path.get_file().get_basename():
				sky_path = path
		elif f.begins_with("item_"):
			_import_sprite(path, "items/%s.png" % f.get_basename(), Vector2i(64, 64), Vector2i(48, 40), true)
		elif f.begins_with("building_"):
			var size: Vector2i = BUILDING_SIZES.get(f.get_basename(), Vector2i(64, 64))
			_import_sprite(path, "buildings/%s.png" % f.get_basename(), size, size, true)
		elif f.begins_with("icon_"):
			_import_sprite(path, "ui/%s.png" % f.get_basename(), Vector2i(64, 64), Vector2i(56, 56), false)
	_import_npc_sheets(sheets)
	if sky_path != "" and not measure_only:
		var sky := _load(sky_path)
		sky.resize(roundi(sky.get_width() * 540.0 / sky.get_height()), 540, Image.INTERPOLATE_LANCZOS)
		# Repeats horizontally in game: min-error wrap seam (columns only).
		var b := roundi(sky.get_width() * 0.12)
		var wrapped := _wrap_cols(sky.get_data(), sky.get_width(), sky.get_height(), b)
		sky = Image.create_from_data(sky.get_width() - b, sky.get_height(), false, Image.FORMAT_RGBA8, wrapped)
		_save(sky, "backgrounds/sky_surface.png")
		report.append("%s -> backgrounds/sky_surface.png" % sky_path.get_file())
	if not measure_only:
		for key in terrain:
			var paths: Array = terrain[key]
			paths.sort()
			_import_terrain(key, paths)
	for line in report:
		print(line)
	quit(0)


# --- NPC sheets ----------------------------------------------------------------

## Slices and measures one sheet (no output yet). Empty dict if not a sheet.
func _analyze_npc(path: String, base: String) -> Dictionary:
	var parts := base.split("_")  # npc, role, anim
	if parts.size() < 3:
		return {}
	var img := _load(path)
	_chroma_key(img)
	var k := float(MEASURE_H) / img.get_height()
	var sm := img.duplicate() as Image
	sm.resize(maxi(1, roundi(img.get_width() * k)), MEASURE_H, Image.INTERPOLATE_BILINEAR)
	var sl := _slice(sm)
	var rects: Array[Rect2i] = sl.rects
	var metrics: Array = []
	var heights: Array[float] = []
	var heads: Array[float] = []
	for i in rects.size():
		var m := _measure(sl.masked[i], rects[i])
		metrics.append(m)
		heights.append(float(m.feet) - float(m.top))
		heads.append(float(m.head_w))
	heights.sort()
	heads.sort()
	return {"base": base, "role": StringName(parts[1]), "anim": StringName("_".join(parts.slice(2))),
			"img": img, "k": k, "rects": rects, "metrics": metrics, "slice": sl,
			"height": heights[heights.size() / 2] / k, "head": heads[heads.size() / 2] / k}


## One scale per sheet. A role's walk sheet sets the scale from the
## head-top-to-feet height (same body size for every role); its other sheets
## (crouching dig, stretched climb) match the walk sheet's head width.
## Roles without a walk sheet fall back to the height rule.
func _import_npc_sheets(sheets: Array[Dictionary]) -> void:
	var head_px: Dictionary = {}  # role -> head width in cell px
	for s in sheets:
		if s.anim == &"walk":
			var target := CHAR_HEIGHT + float(HAT_ALLOWANCE.get(s.role, 0.0))
			s["scale"] = target / float(s.height)
			head_px[s.role] = float(s.head) * float(s.scale)
	for s in sheets:
		if s.has("scale"):
			continue
		if head_px.has(s.role) and float(s.head) > 0.0:
			s["scale"] = float(head_px[s.role]) / float(s.head)
		else:
			s["scale"] = (CHAR_HEIGHT + float(HAT_ALLOWANCE.get(s.role, 0.0))) / float(s.height)
	for s in sheets:
		var line := "%s: %d frames, height %.0f, head %.0f (orig px), scale %.3f" % [
				s.base, (s.rects as Array).size(), s.height, s.head, s.scale]
		if measure_only:
			report.append(line)
		else:
			_write_npc_sheet(s, line)


func _write_npc_sheet(s: Dictionary, line: String) -> void:
	var img: Image = s.img
	var k: float = s.k
	var scale: float = s.scale
	var rects: Array = s.rects
	var metrics: Array = s.metrics
	var base: String = s.base
	var cs := cell_size(s.anim)
	var wide: bool = s.anim in WIDE_ANIMS
	var out := Image.create(cs.x * rects.size(), cs.y, false, Image.FORMAT_RGBA8)
	var clipped_total := 0
	for i in rects.size():
		var r: Rect2i = rects[i]
		var m: Dictionary = metrics[i]
		var orig := Rect2i(roundi(r.position.x / k), 0, roundi(r.size.x / k), img.get_height()).intersection(Rect2i(Vector2i.ZERO, img.get_size()))
		var frame := img.get_region(orig)
		frame.fix_alpha_edges()
		var fw := maxi(1, roundi(frame.get_width() * scale))
		var fh := maxi(1, roundi(frame.get_height() * scale))
		frame.resize(fw, fh, Image.INTERPOLATE_LANCZOS)
		_mask_foreign(frame, s.slice, s.slice.frames[i], orig.position.x, scale, k)
		var feet_y: float = (float(m.feet) + 1.0) / k * scale
		# Lying poses centre on the whole figure; standing ones on the torso.
		var cx: float = (float(m.bbox_cx if wide else m.cx) / k - orig.position.x) * scale
		var dst := Vector2i(roundi(cs.x / 2.0 - cx), roundi(cs.y - feet_y))
		var cell := Image.create(cs.x, cs.y, false, Image.FORMAT_RGBA8)
		cell.blit_rect(frame, Rect2i(Vector2i.ZERO, frame.get_size()), dst)
		clipped_total += _count_clipped(frame, dst, cs)
		_clean_sprite(cell)
		out.blit_rect(cell, Rect2i(Vector2i.ZERO, cs), Vector2i(i * cs.x, 0))
	var rel := "characters/%s.png" % base
	_save(out, rel)
	report.append(line + ("  CLIPPED %d px" % clipped_total if clipped_total > 0 else "") + " -> " + rel)


## Slices a sheet (small-image coords). Frame count = the 1:2 cell count of
## the sheet. Every connected opaque blob is given to the frame its centroid
## falls in (so a pickaxe overhanging the neighbour's column, or touching
## columns between frames, stays with its own figure); tiny blobs are dust
## and dropped. Returns {rects, labels, owner, masked} where masked[i] is a
## copy of sm holding only frame i's blobs.
func _slice(sm: Image) -> Dictionary:
	var w := sm.get_width()
	var h := sm.get_height()
	var n := maxi(1, roundi(w / (h * 0.5)))
	var data := sm.get_data()
	var labels := PackedInt32Array()
	labels.resize(w * h)
	labels.fill(-1)
	var sizes: Array[int] = []
	var sum_x: Array[float] = []
	var boxes: Array[Rect2i] = []
	for start in w * h:
		if labels[start] != -1 or data[start * 4 + 3] < ALPHA_SOLID:
			continue
		var id := sizes.size()
		var count := 0
		var sx := 0.0
		var box := Rect2i(start % w, start / w, 1, 1)
		var stack: Array[int] = [start]
		labels[start] = id
		while not stack.is_empty():
			var p: int = stack.pop_back()
			var px := p % w
			var py := p / w
			count += 1
			sx += px
			box = box.expand(Vector2i(px, py)).expand(Vector2i(px + 1, py + 1))
			for q in [p - 1 if px > 0 else -1, p + 1 if px < w - 1 else -1, p - w if py > 0 else -1, p + w if py < h - 1 else -1]:
				if q >= 0 and labels[q] == -1 and data[q * 4 + 3] >= ALPHA_SOLID:
					labels[q] = id
					stack.append(q)
		sizes.append(count)
		sum_x.append(sx)
		boxes.append(box)
	var largest: int = sizes.max() if not sizes.is_empty() else 0
	var owner := PackedInt32Array()
	owner.resize(sizes.size())
	var frame_box: Array = []
	frame_box.resize(n)
	for id in sizes.size():
		if sizes[id] < maxi(4, roundi(largest * 0.003)):
			owner[id] = -1
			continue
		var f := clampi(int(sum_x[id] / sizes[id] / (w / float(n))), 0, n - 1)
		owner[id] = f
		frame_box[f] = boxes[id] if frame_box[f] == null else (frame_box[f] as Rect2i).merge(boxes[id])
	var rects: Array[Rect2i] = []
	var masked: Array[Image] = []
	var frame_ids: Array[int] = []
	for f in n:
		if frame_box[f] == null:
			continue
		var b: Rect2i = frame_box[f]
		rects.append(Rect2i(maxi(0, b.position.x - 3), 0, mini(w, b.end.x + 3) - maxi(0, b.position.x - 3), h))
		var md := data.duplicate()
		for p in w * h:
			var l := labels[p]
			if l == -1 or owner[l] != f:
				md[p * 4 + 3] = 0
		masked.append(Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, md))
		frame_ids.append(f)
	return {"rects": rects, "labels": labels, "owner": owner, "masked": masked, "frames": frame_ids, "w": w}


## {top, feet, cx} of one frame in small-image coords.
func _measure(sm: Image, r: Rect2i) -> Dictionary:
	var w := sm.get_width()
	var data := sm.get_data()
	var rows := PackedInt32Array()
	rows.resize(r.size.y)
	var maxc := 1
	for y in r.size.y:
		var c := 0
		var row := (r.position.y + y) * w * 4
		for x in range(r.position.x, r.end.x):
			if data[row + x * 4 + 3] >= ALPHA_SOLID:
				c += 1
		rows[y] = c
		maxc = maxi(maxc, c)
	var top := 0
	for y in r.size.y - 3:
		if rows[y] >= DENSE_TOP * maxc and rows[y + 1] >= DENSE_TOP * maxc and rows[y + 2] >= DENSE_TOP * maxc:
			top = y
			break
	var feet := r.size.y - 1
	for y in range(r.size.y - 1, -1, -1):
		if rows[y] >= DENSE_FEET * maxc:
			feet = y
			break
	# Soles: continue down through thin rows directly below the dense feet.
	while feet + 1 < r.size.y and rows[feet + 1] >= 0.03 * maxc:
		feet += 1
	var h := feet - top
	var xs: Array[int] = []
	for y in range(int(feet - 0.62 * h), int(feet - 0.35 * h)):
		var row := (r.position.y + y) * w * 4
		for x in range(r.position.x, r.end.x):
			if data[row + x * 4 + 3] >= ALPHA_SOLID:
				xs.append(x)
	xs.sort()
	var cx := float(xs[xs.size() / 2]) if not xs.is_empty() else r.position.x + r.size.x / 2.0
	# Head width: widest contiguous opaque run through the head centre in the
	# top band (helmet brim / hair), stable across poses of one character.
	var hx := -1
	var row0 := (r.position.y + top + 3) * w * 4
	var row_xs: Array[int] = []
	for x in range(r.position.x, r.end.x):
		if data[row0 + x * 4 + 3] >= ALPHA_SOLID:
			row_xs.append(x)
	if not row_xs.is_empty():
		hx = row_xs[row_xs.size() / 2]
	var head_w := 0
	if hx >= 0:
		for y in range(top + 2, top + int(0.22 * h)):
			var row := (r.position.y + y) * w * 4
			if data[row + hx * 4 + 3] < ALPHA_SOLID:
				continue
			var a := hx
			while a > r.position.x and data[row + (a - 1) * 4 + 3] >= ALPHA_SOLID:
				a -= 1
			var b := hx
			while b < r.end.x - 1 and data[row + (b + 1) * 4 + 3] >= ALPHA_SOLID:
				b += 1
			head_w = maxi(head_w, b - a + 1)
	var bx: Array[int] = []
	for y in range(top, feet + 1):
		var row := (r.position.y + y) * w * 4
		for x in range(r.position.x, r.end.x):
			if data[row + x * 4 + 3] >= ALPHA_SOLID:
				bx.append(x)
				break
		for x in range(r.end.x - 1, r.position.x - 1, -1):
			if data[row + x * 4 + 3] >= ALPHA_SOLID:
				bx.append(x)
				break
	var bbox_cx: float = (bx.min() + bx.max()) / 2.0 if not bx.is_empty() else cx
	return {"top": float(top), "feet": float(feet), "cx": cx, "head_w": float(head_w), "bbox_cx": bbox_cx}


## Clears pixels of a scaled frame that belong to another frame's blob (or to
## dropped dust), looked up in the small-image labels.
func _mask_foreign(frame: Image, sl: Dictionary, f: int, ox: int, scale: float, k: float) -> void:
	var labels: PackedInt32Array = sl.labels
	var owner: PackedInt32Array = sl.owner
	var smw: int = sl.w
	var smh := labels.size() / smw
	var fw := frame.get_width()
	var fh := frame.get_height()
	var d := frame.get_data()
	for y in fh:
		var sy := clampi(int((y + 0.5) / scale * k), 0, smh - 1)
		for x in fw:
			var sx := clampi(int((ox + (x + 0.5) / scale) * k), 0, smw - 1)
			var l := labels[sy * smw + sx]
			if l >= 0 and owner[l] != f:
				d[(y * fw + x) * 4 + 3] = 0
	frame.set_data(fw, fh, false, Image.FORMAT_RGBA8, d)


func _count_clipped(frame: Image, dst: Vector2i, cs: Vector2i) -> int:
	var n := 0
	var data := frame.get_data()
	var fw := frame.get_width()
	for y in frame.get_height():
		for x in fw:
			var px := dst.x + x
			var py := dst.y + y
			if (px < 0 or py < 0 or px >= cs.x or py >= cs.y) and data[(y * fw + x) * 4 + 3] >= ALPHA_SOLID:
				n += 1
	return n


## Drops faint alpha, removes detached specks, replaces fringe colours on
## semi-transparent edge pixels with the colour of their opaque neighbours.
func _clean_sprite(img: Image) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var d := img.get_data()
	for i in w * h:
		if d[i * 4 + 3] < 24:
			d[i * 4 + 3] = 0
	# Connected components on alpha >= 32 (4-neighbour).
	var label := PackedInt32Array()
	label.resize(w * h)
	label.fill(-1)
	var sizes: Array[int] = []
	for start in w * h:
		if label[start] != -1 or d[start * 4 + 3] < 32:
			continue
		var id := sizes.size()
		var count := 0
		var stack: Array[int] = [start]
		label[start] = id
		while not stack.is_empty():
			var p: int = stack.pop_back()
			count += 1
			var px := p % w
			var py := p / w
			for q in [p - 1 if px > 0 else -1, p + 1 if px < w - 1 else -1, p - w if py > 0 else -1, p + w if py < h - 1 else -1]:
				if q >= 0 and label[q] == -1 and d[q * 4 + 3] >= 32:
					label[q] = id
					stack.append(q)
		sizes.append(count)
	if sizes.is_empty():
		img.set_data(w, h, false, Image.FORMAT_RGBA8, d)
		return
	var largest: int = sizes.max()
	var min_keep := maxi(SPECK_MIN_PX, roundi(largest * SPECK_MIN_FRACTION))
	var keep := PackedByteArray()
	keep.resize(w * h)
	for i in w * h:
		if label[i] >= 0 and sizes[label[i]] >= min_keep:
			keep[i] = 1
	# Remove dropped components and faint pixels not touching a kept pixel.
	for i in w * h:
		if keep[i] == 1 or d[i * 4 + 3] == 0:
			continue
		var near := false
		if label[i] == -1:
			var px := i % w
			var py := i / w
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					var x := px + dx
					var y := py + dy
					if x >= 0 and y >= 0 and x < w and y < h and keep[y * w + x] == 1:
						near = true
		if not near:
			d[i * 4 + 3] = 0
	# Fringe: semi-transparent pixels take the mean colour of opaque neighbours.
	var src := d.duplicate()
	for i in w * h:
		var a := src[i * 4 + 3]
		if a == 0 or a >= 230:
			continue
		var px := i % w
		var py := i / w
		var r := 0
		var g := 0
		var b := 0
		var n := 0
		for rad in [1, 2]:
			for dy in range(-rad, rad + 1):
				for dx in range(-rad, rad + 1):
					var x := px + dx
					var y := py + dy
					if x < 0 or y < 0 or x >= w or y >= h:
						continue
					var j := (y * w + x) * 4
					if src[j + 3] >= 230:
						r += src[j]
						g += src[j + 1]
						b += src[j + 2]
						n += 1
			if n > 0:
				break
		if n > 0:
			d[i * 4] = r / n
			d[i * 4 + 1] = g / n
			d[i * 4 + 2] = b / n
	img.set_data(w, h, false, Image.FORMAT_RGBA8, d)


# --- Terrain -------------------------------------------------------------------

## High-res world-space material texture for the smooth terrain renderer
## (D-027): variant 1 made seamless at HD_WORK px, then HD_SIZE px.
func _import_terrain_hd(key: String, path: String) -> void:
	var img := _load(path)
	var side := mini(img.get_width(), img.get_height())
	img = img.get_region(Rect2i(0, 0, side, side))
	img.resize(HD_WORK, HD_WORK, Image.INTERPOLATE_LANCZOS)
	img = seamless(img, HD_WORK - HD_SIZE)
	var d := img.get_data()
	for p in HD_SIZE * HD_SIZE:
		d[p * 4 + 3] = 255
	img.set_data(HD_SIZE, HD_SIZE, false, Image.FORMAT_RGBA8, d)
	var rel := "terrain_hd/terrain_%s.png" % key
	_save(img, rel)
	report.append("terrain %s HD -> %s" % [key, rel])


func _import_terrain(key: String, paths: Array) -> void:
	if key != "backwall_dug":
		_import_terrain_hd(key, paths[0])
	var strip := Image.create(TILE * paths.size(), TILE, false, Image.FORMAT_RGBA8)
	var first: Image = null
	for i in paths.size():
		var img := _load(paths[i])
		var side := mini(img.get_width(), img.get_height())
		img = img.get_region(Rect2i(0, 0, side, side))
		img.resize(TERRAIN_WORK, TERRAIN_WORK, Image.INTERPOLATE_LANCZOS)
		img = seamless(img, roundi(TERRAIN_WORK * TERRAIN_BLEND))
		# Variants sit next to each other in any order: give every variant the
		# border of variant 1 so all combinations join without seams.
		if first == null:
			first = img.duplicate() as Image  # img is resized in place below
		else:
			img = match_border(first, img, roundi(img.get_width() * TERRAIN_BORDER))
		img.resize(TILE, TILE, Image.INTERPOLATE_LANCZOS)
		var d := img.get_data()
		for p in TILE * TILE:
			d[p * 4 + 3] = 255
		img.set_data(TILE, TILE, false, Image.FORMAT_RGBA8, d)
		strip.blit_rect(img, Rect2i(0, 0, TILE, TILE), Vector2i(i * TILE, 0))
	var rel := "backgrounds/backwall_dug.png" if key == "backwall_dug" else "terrain/terrain_%s.png" % key
	_save(strip, rel)
	report.append("terrain %s: %d variants -> %s" % [key, paths.size(), rel])


## Seamless tile of size (n - b), image-quilting style: the first b columns
## overlap the content just past the right edge (src[m + x]); a minimum-error
## path through that overlap decides where the image switches from the
## wrapped content to the original (2 px feather), so large shapes such as
## cobbles are not ghosted by a cross-fade. Then the same for rows.
static func seamless(img: Image, b: int) -> Image:
	var n := img.get_width()
	var d := _wrap_cols(img.get_data(), n, n, b)          # (n-b) x n
	d = _transpose(d, n - b, n)                           # n x (n-b)
	d = _wrap_cols(d, n, n - b, b)                        # (n-b) x (n-b)
	d = _transpose(d, n - b, n - b)
	return Image.create_from_data(n - b, n - b, false, Image.FORMAT_RGBA8, d)


static func _wrap_cols(src: PackedByteArray, w: int, h: int, b: int) -> PackedByteArray:
	var m := w - b
	# Error of choosing the original (B = src[x]) vs the wrapped (A = src[m+x]).
	var err := PackedFloat32Array()
	err.resize(h * b)
	for y in h:
		for x in b:
			var s := (y * w + x) * 4
			var s2 := (y * w + m + x) * 4
			var e := 0.0
			for c in 3:
				var dv := float(src[s + c]) - float(src[s2 + c])
				e += dv * dv
			err[y * b + x] = e
	# Dynamic programming: cheapest top-to-bottom path, staying 2 px from the
	# overlap borders so both sides keep some of their own pixels.
	var cost := err.duplicate()
	var lo := 2
	var hi := b - 3
	for y in range(1, h):
		for x in b:
			var best := INF
			for dx in [-1, 0, 1]:
				var px: int = x + dx
				if px >= lo and px <= hi:
					best = minf(best, cost[(y - 1) * b + px])
			cost[y * b + x] = err[y * b + x] + (best if best < INF else 1e12)
	var cut := PackedInt32Array()
	cut.resize(h)
	var bx := lo
	for x in range(lo, hi + 1):
		if cost[(h - 1) * b + x] < cost[(h - 1) * b + bx]:
			bx = x
	cut[h - 1] = bx
	for y in range(h - 2, -1, -1):
		var px := cut[y + 1]
		var nb := px
		for dx in [-1, 1]:
			var q: int = px + dx
			if q >= lo and q <= hi and cost[y * b + q] < cost[y * b + nb]:
				nb = q
		cut[y] = nb
	var out := PackedByteArray()
	out.resize(m * h * 4)
	for y in h:
		for x in m:
			var o := (y * m + x) * 4
			var s := (y * w + x) * 4
			if x < b:
				var s2 := (y * w + m + x) * 4
				var t := clampf((x - cut[y] + 2) / 4.0, 0.0, 1.0)  # 0 = wrapped, 1 = original
				for c in 4:
					out[o + c] = roundi(lerpf(src[s2 + c], src[s + c], t))
			else:
				for c in 4:
					out[o + c] = src[s + c]
	return out


## `inner` with its outer band replaced by `outer`'s, switching along
## minimum-error paths on all four sides (2 px feather).
static func match_border(outer: Image, inner: Image, e: int) -> Image:
	var w := inner.get_width()
	var a := outer.get_data()
	var b := inner.get_data()
	var at := _transpose(a, w, w)
	var bt := _transpose(b, w, w)
	var left := _cut_path(a, b, w, 0, e)
	var right := _cut_path(a, b, w, w - e, w)
	var top := _cut_path(at, bt, w, 0, e)
	var bottom := _cut_path(at, bt, w, w - e, w)
	var out := PackedByteArray()
	out.resize(w * w * 4)
	for y in w:
		for x in w:
			var t := clampf((x - left[y] + 2) / 4.0, 0.0, 1.0)
			t = minf(t, clampf((right[y] - x + 2) / 4.0, 0.0, 1.0))
			t = minf(t, clampf((y - top[x] + 2) / 4.0, 0.0, 1.0))
			t = minf(t, clampf((bottom[x] - y + 2) / 4.0, 0.0, 1.0))
			var o := (y * w + x) * 4
			for c in 4:
				out[o + c] = roundi(lerpf(a[o + c], b[o + c], t))
	return Image.create_from_data(w, w, false, Image.FORMAT_RGBA8, out)


## Minimum-error top-to-bottom path (x per row) between two same-size square
## images inside columns [x0, x1), staying 2 px from the band edges.
static func _cut_path(a: PackedByteArray, b: PackedByteArray, w: int, x0: int, x1: int) -> PackedInt32Array:
	var bw := x1 - x0
	var cost := PackedFloat32Array()
	cost.resize(w * bw)
	for y in w:
		for i in bw:
			var o := (y * w + x0 + i) * 4
			var e := 0.0
			for c in 3:
				var dv := float(a[o + c]) - float(b[o + c])
				e += dv * dv
			var best := 0.0
			if y > 0:
				best = INF
				for di in [-1, 0, 1]:
					var q: int = i + di
					if q >= 2 and q <= bw - 3:
						best = minf(best, cost[(y - 1) * bw + q])
				if best == INF:
					best = 1e12
			cost[y * bw + i] = e + best
	var path := PackedInt32Array()
	path.resize(w)
	var bi := 2
	for i in range(2, bw - 2):
		if cost[(w - 1) * bw + i] < cost[(w - 1) * bw + bi]:
			bi = i
	path[w - 1] = bi
	for y in range(w - 2, -1, -1):
		var p := path[y + 1]
		var nb := p
		for di in [-1, 1]:
			var q: int = p + di
			if q >= 2 and q <= bw - 3 and cost[y * bw + q] < cost[y * bw + nb]:
				nb = q
		path[y] = nb
	for y in w:
		path[y] += x0
	return path


static func _transpose(src: PackedByteArray, w: int, h: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(w * h * 4)
	for y in h:
		for x in w:
			var s := (y * w + x) * 4
			var o := (x * h + y) * 4
			for c in 4:
				out[o + c] = src[s + c]
	return out


# --- Ladder ------------------------------------------------------------------------

## Crops the ladder to exactly 3 rung periods (half a period above the first
## rung) so stacked tiles keep even rung spacing, then scales to one tile.
func _import_ladder(path: String) -> void:
	var img := _load(path)
	_chroma_key(img)
	var w := img.get_width()
	var h := img.get_height()
	var data := img.get_data()
	var rung_rows: Array[int] = []
	for y in h:
		var c := 0
		for x in range(int(w * 0.45), int(w * 0.55)):
			if data[(y * w + x) * 4 + 3] >= ALPHA_SOLID:
				c += 1
		if c >= int(w * 0.1 * 0.8):
			rung_rows.append(y)
	var centres: Array[float] = []
	var i := 0
	while i < rung_rows.size():
		var s := i
		while i + 1 < rung_rows.size() and rung_rows[i + 1] == rung_rows[i] + 1:
			i += 1
		centres.append((rung_rows[s] + rung_rows[i]) / 2.0)
		i += 1
	var crop := Rect2i(0, 0, w, h)
	if centres.size() >= 2:
		var period := (centres[-1] - centres[0]) / (centres.size() - 1)
		var y0 := roundi(centres[0] - period / 2.0)
		var hh := roundi(period * centres.size())
		crop = Rect2i(0, maxi(0, y0), w, mini(hh, h - maxi(0, y0)))
	var tile := img.get_region(crop)
	tile.fix_alpha_edges()
	tile.resize(TILE, TILE, Image.INTERPOLATE_LANCZOS)
	_save(tile, "structures/ladder.png")
	report.append("ladder: %d rungs, crop %s -> structures/ladder.png" % [centres.size(), crop])


# --- Single sprites (items, buildings, icons) ---------------------------------------

## Keys out a flat green background, trims to the content, fits it into
## `fit` (keeping aspect) and places it in a `canvas`-sized image, bottom-
## centred (`bottom`) or centred; then cleans specks and fringes.
func _import_sprite(path: String, rel: String, canvas: Vector2i, fit: Vector2i, bottom: bool) -> void:
	var img := _load(path)
	_chroma_key(img)
	var used := img.get_used_rect()
	if used.size.x <= 0:
		report.append("%s: empty, skipped" % path.get_file())
		return
	img = img.get_region(used)
	img.fix_alpha_edges()
	var s := minf(float(fit.x) / used.size.x, float(fit.y) / used.size.y)
	img.resize(maxi(1, roundi(used.size.x * s)), maxi(1, roundi(used.size.y * s)), Image.INTERPOLATE_LANCZOS)
	var out := Image.create(canvas.x, canvas.y, false, Image.FORMAT_RGBA8)
	var dst := Vector2i((canvas.x - img.get_width()) / 2,
			canvas.y - img.get_height() if bottom else (canvas.y - img.get_height()) / 2)
	out.blit_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), dst)
	_clean_sprite(out)
	_save(out, rel)
	report.append("%s -> %s" % [path.get_file(), rel])


## Opaque image with a green (#00FF00-ish) border -> green pixels transparent.
func _chroma_key(img: Image) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var c := img.get_pixel(0, 0)
	if c.a < 0.5 or not (c.g > 0.6 and c.r < 0.4 and c.b < 0.4):
		return
	var d := img.get_data()
	for i in w * h:
		var r := d[i * 4]
		var g := d[i * 4 + 1]
		var b := d[i * 4 + 2]
		if g > 150 and r < 120 and b < 120:
			d[i * 4 + 3] = 0
		elif g > r + 40 and g > b + 40:
			d[i * 4 + 1] = maxi(r, b)  # de-spill green on edges
	img.set_data(w, h, false, Image.FORMAT_RGBA8, d)


# --- IO --------------------------------------------------------------------------------

func _load(path: String) -> Image:
	var img := Image.load_from_file(path)
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	return img


func _save(img: Image, rel: String) -> void:
	var path := dst_dir.path_join(rel)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var err := img.save_png(path)
	if err != OK:
		push_error("save failed %s: %s" % [path, err])
	_ensure_image_import(path)


## Production art is imported as an Image resource (ASSET_SPEC §9): writes an
## .import stub with importer="image" (keeping an existing uid); Godot fills in
## the rest on the next import (run_tests / export / editor).
func _ensure_image_import(path: String) -> void:
	var imp := ProjectSettings.globalize_path(path) + ".import"
	var uid := ""
	if FileAccess.file_exists(imp):
		var text := FileAccess.get_file_as_string(imp)
		if text.contains("importer=\"image\""):
			return
		for line in text.split("\n"):
			if line.begins_with("uid="):
				uid = line
	var f := FileAccess.open(imp, FileAccess.WRITE)
	f.store_string("[remap]\n\nimporter=\"image\"\ntype=\"Image\"\n" + (uid + "\n" if uid != "" else ""))
	f.close()


static func cell_size(anim: StringName) -> Vector2i:
	return WIDE_CELL if anim in WIDE_ANIMS else CELL
