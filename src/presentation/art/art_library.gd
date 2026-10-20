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
const NPC_CELL := Vector2i(96, 192)
const TERRAIN_VARIANTS := 4

## Animation frame rates (frames per second) used for production sheets.
const ANIM_FPS := {
	&"idle": 4.0, &"walk": 10.0, &"climb": 8.0, &"dig": 8.0,
	&"carry": 10.0, &"build": 8.0, &"sleep": 2.0, &"fall": 8.0,
}

static var _cache: Dictionary = {}  # path -> Texture2D or null


## Texture at `rel` under base_dir, or null. Loads imported resources first
## (exported builds), then raw PNGs (files dropped in before re-import).
static func texture(rel: String) -> Texture2D:
	var path := base_dir.path_join(rel)
	if _cache.has(path):
		return _cache[path]
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		tex = load(path) as Texture2D
	elif FileAccess.file_exists(path):
		var img := Image.load_from_file(path)
		if img != null and not img.is_empty():
			tex = ImageTexture.create_from_image(img)
	_cache[path] = tex
	return tex


## Same lookup as texture() but returns the RGBA8 image (for atlas building).
static func image(rel: String) -> Image:
	var tex := texture(rel)
	if tex == null:
		return null
	var img := tex.get_image()
	if img == null or img.is_empty():
		return null
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	return img


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


## Number of frames in a sheet (cells are NPC_CELL, one row).
static func frame_count(sheet: Texture2D) -> int:
	return maxi(1, sheet.get_width() / NPC_CELL.x)


## Region of frame `i` in a one-row sheet.
static func frame_region(i: int, count: int) -> Rect2:
	return Rect2(Vector2(posmod(i, maxi(count, 1)) * NPC_CELL.x, 0), Vector2(NPC_CELL))


static func item_texture(material: StringName) -> Texture2D:
	return texture(item_path(material))
