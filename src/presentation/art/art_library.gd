class_name ArtLibrary
extends RefCounted
## Finds production art (docs/art/ASSET_SPEC.md) by file name and hands it to
## the views. Every getter returns null when the file is missing, and callers
## then draw the procedural fallback — the game never depends on art files.
## Results (including misses) are cached for the whole run.

## Root of the production art tree. Tests point this at user:// folders.
static var base_dir := "res://assets/production/"

## Fixed sprite-sheet cell sizes (ASSET_SPEC §4, §6). Cells have no padding.
const TILE_PX := 64
const NPC_CELL := Vector2i(128, 192)
## Lying animations (sleep) use a wider cell; feet-line pivot unchanged.
const WIDE_ANIMS: Array[StringName] = [&"sleep"]
const WIDE_CELL := Vector2i(192, 192)
## Where the hands hold a carried item in a sheet cell (feet pivot space).
const SHEET_CARRY_AT := Vector2(22, -80)
## Missing animation -> sheets to try instead, in order (ASSET_SPEC §6,
## D-027). Only idle borrows a still walk frame (the view adds breathing);
## every other missing animation uses the code rig (empty list) instead of
## sliding borrowed walk frames.
const NPC_FALLBACK := {
	&"idle": [&"walk"], &"walk": [], &"carry": [], &"climb": [],
	&"dig": [], &"build": [], &"sleep": [], &"fall": [],
}
## Animations that, when borrowed from a moving sheet, show one still frame.
const HOLD_ANIMS: Array[StringName] = [&"idle", &"sleep", &"fall"]
const TERRAIN_VARIANTS := 4

## Animation frame rates (frames per second) used for production sheets.
const ANIM_FPS := {
	&"idle": 4.0, &"walk": 10.0, &"climb": 8.0, &"dig": 8.0,
	&"carry": 10.0, &"build": 8.0, &"sleep": 2.0, &"fall": 8.0,
}

static var _cache: Dictionary = {}  # path -> Texture2D or null


## Texture at `rel` under base_dir, or null (cached, misses included).
static func texture(rel: String) -> Texture2D:
	var path := base_dir.path_join(rel)
	if _cache.has(path):
		return _cache[path]
	var tex: Texture2D = null
	var img := image(rel)
	if img != null:
		tex = ImageTexture.create_from_image(img)
	elif ResourceLoader.exists(path):
		tex = load(path) as Texture2D
	_cache[path] = tex
	return tex


## RGBA8 image at `rel`, or null. Production PNGs are imported as Image
## resources (ASSET_SPEC §9): the pixels stay on the CPU, because reading a
## GPU texture back (Texture2D.get_image) returns garbage in the Web build.
## Falls back to a raw PNG (file dropped in before re-import). A copy is
## returned, so callers may modify it.
static func image(rel: String) -> Image:
	var path := base_dir.path_join(rel)
	var key := "img|" + path
	if not _cache.has(key):
		var img: Image = null
		if ResourceLoader.exists(path, "Image"):
			img = load(path) as Image
		if img == null and FileAccess.file_exists(path) and not ResourceLoader.exists(path):
			img = Image.load_from_file(path)
		if img != null and not img.is_empty():
			img = img.duplicate() as Image
			if img.is_compressed():
				img.decompress()
			img.convert(Image.FORMAT_RGBA8)
		else:
			img = null
		_cache[key] = img
	var cached: Image = _cache[key]
	return cached.duplicate() as Image if cached else null


static func clear_cache() -> void:
	_cache.clear()


# --- Names (ASSET_SPEC §8) --------------------------------------------------

static func terrain_path(material: StringName) -> String:
	return "terrain/terrain_%s.png" % material


static func structure_path(key: StringName) -> String:
	return "structures/%s.png" % key


static func npc_sheet_path(role: StringName, anim: StringName) -> String:
	return "characters/npc_%s_%s.png" % [role, anim]


static func item_path(material: StringName) -> String:
	return "items/item_%s.png" % material


static func building_path(key: StringName) -> String:
	return "buildings/building_%s.png" % key


static func background_path(key: StringName) -> String:
	return "backgrounds/%s.png" % key


static func ui_icon_path(key: StringName) -> String:
	return "ui/icon_%s.png" % key


# --- Typed getters ----------------------------------------------------------

## Terrain strip: TERRAIN_VARIANTS cells of TILE_PX side by side. Returns the
## image scaled to `px` tiles, or null when missing / wrong size.
static func terrain_strip(material: StringName, px: int) -> Image:
	var img := image(terrain_path(material))
	if img == null or img.get_height() <= 0 or img.get_width() < img.get_height():
		return null
	var variants := clampi(img.get_width() / img.get_height(), 1, TERRAIN_VARIANTS)
	var out := Image.create(px * variants, px, false, Image.FORMAT_RGBA8)
	for v in variants:
		var cell := img.get_region(Rect2i(v * img.get_height(), 0, img.get_height(), img.get_height()))
		if cell.get_width() != px:
			cell.resize(px, px, Image.INTERPOLATE_LANCZOS)
		out.blit_rect(cell, Rect2i(0, 0, px, px), Vector2i(v * px, 0))
	return out


## Single-tile image (ladder etc.) scaled to px, or null.
static func tile_image(rel: String, px: int) -> Image:
	var img := image(rel)
	if img == null:
		return null
	if img.get_size() != Vector2i(px, px):
		img.resize(px, px, Image.INTERPOLATE_LANCZOS)
	return img


static func npc_sheet(role: StringName, anim: StringName) -> Texture2D:
	var tex := texture(npc_sheet_path(role, anim))
	if tex == null or tex.get_height() < NPC_CELL.y or tex.get_width() < NPC_CELL.x:
		return null
	return tex


## Sheet to show for (role, anim): the anim's own sheet, else the first
## available fallback in NPC_FALLBACK. Returns {} when the role has none of
## them (caller uses the procedural rig). Keys: sheet, anim (sheet's anim),
## hold (true = show one standing frame instead of animating), frame (that
## standing frame). Cached.
static func npc_anim_sheet(role: StringName, anim: StringName) -> Dictionary:
	var ck := "anim|%s|%s|%s" % [base_dir, role, anim]
	if _cache.has(ck):
		return _cache[ck]
	var res := {}
	var tex := npc_sheet(role, anim)
	if tex != null:
		res = {"sheet": tex, "anim": anim, "hold": false, "frame": 0}
	else:
		for alt: StringName in NPC_FALLBACK.get(anim, []):
			tex = npc_sheet(role, alt)
			if tex != null:
				var hold: bool = anim in HOLD_ANIMS and not (alt in HOLD_ANIMS)
				res = {"sheet": tex, "anim": alt, "hold": hold,
						"frame": stand_frame(image(npc_sheet_path(role, alt))) if hold else 0}
				break
	_cache[ck] = res
	return res


## Index of the narrowest frame of a sheet (legs together = a standing pose).
static func stand_frame(img: Image) -> int:
	if img == null or img.is_empty():
		return 0
	var best := 0
	var best_w := INF
	for f in maxi(1, img.get_width() / NPC_CELL.x):
		var used := img.get_region(Rect2i(f * NPC_CELL.x, 0, NPC_CELL.x, NPC_CELL.y)).get_used_rect()
		if used.size.x > 0 and used.size.x < best_w:
			best_w = used.size.x
			best = f
	return best


## Per-sheet motion metrics, measured once from the pixels (cached):
## "cycle_px" = ground distance one full loop of the sheet covers (walk-type
## sheets: two steps, from the spread of the soles), "dx" = per-frame x
## offsets that put each frame's head centre on the sheet median (cancels
## head wobble between AI frames, clamped to a few px).
static func sheet_metrics(role: StringName, anim: StringName) -> Dictionary:
	var ck := "metrics|%s|%s|%s" % [base_dir, role, anim]
	if _cache.has(ck):
		return _cache[ck]
	var img := image(npc_sheet_path(role, anim))
	var res := {"cycle_px": float(TILE_PX), "dx": PackedFloat32Array()}
	if img != null:
		var n := maxi(1, img.get_width() / NPC_CELL.x)
		var soles: Array[int] = []
		var heads: Array[float] = []
		for f in n:
			var cell := img.get_region(Rect2i(f * NPC_CELL.x, 0, NPC_CELL.x, NPC_CELL.y))
			var sole := cell.get_region(Rect2i(0, NPC_CELL.y - 10, NPC_CELL.x, 10)).get_used_rect()
			soles.append(sole.size.x)
			var used := cell.get_used_rect()
			var head := cell.get_region(Rect2i(0, used.position.y, NPC_CELL.x, 28)).get_used_rect()
			heads.append(head.get_center().x if head.size.x > 0 else NPC_CELL.x / 2.0)
		var sorted := heads.duplicate()
		sorted.sort()
		var med: float = sorted[sorted.size() / 2]
		var dx := PackedFloat32Array()
		for h in heads:
			dx.append(clampf(med - h, -4.0, 4.0))
		res["dx"] = dx
		var spread: float = soles.max() - 0.55 * soles.min()
		res["cycle_px"] = clampf(2.0 * spread, 40.0, 160.0)
	_cache[ck] = res
	return res


## Cell size of an animation sheet: NPC_CELL, wider for lying poses.
static func cell_size(anim: StringName) -> Vector2i:
	return WIDE_CELL if anim in WIDE_ANIMS else NPC_CELL


## Number of frames in a sheet of an animation (one row of cell_size cells).
static func frame_count(sheet: Texture2D, anim: StringName = &"") -> int:
	return maxi(1, sheet.get_width() / cell_size(anim).x)


## Region of frame `i` in a one-row sheet.
static func frame_region(i: int, count: int) -> Rect2:
	return Rect2(Vector2(posmod(i, maxi(count, 1)) * NPC_CELL.x, 0), Vector2(NPC_CELL))


static func item_texture(material: StringName) -> Texture2D:
	return texture(item_path(material))
