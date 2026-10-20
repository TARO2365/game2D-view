class_name BuildingView
extends Node2D
## Placed buildings (door, crate, bed, table), visible area only. Placeholder
## flat shapes, obviously not final art.
##
## ART HOOK (Asset Agent, D-020): every building is drawn through
## `_draw_building(key, rect, fill)`, which asks `texture_for(key)`:
## `textures[key]` if set, else ArtLibrary `buildings/building_<key>.png`.
## A texture is drawn over the footprint instead of the placeholder shape. The static `draw_shape` is also used for
## build-menu icons and order ghosts.

const OUTLINE := Color(0.08, 0.06, 0.05)
const WOOD := Color(0.62, 0.43, 0.24)       # PLACEHOLDER
const WOOD_DARK := Color(0.4, 0.27, 0.15)
const METAL := Color(0.75, 0.75, 0.7)
const BLANKET := Color(0.3, 0.45, 0.8)
const PILLOW := Color(0.92, 0.92, 0.88)
const FILL_BG := Color(0, 0, 0, 0.65)
const FILL_FG := Color(0.4, 0.9, 0.45)
const SELECT_COLOR := Color(1.0, 0.92, 0.25)

var buildings: Buildings
var inventory: Inventory
var tile_px := 64
## key (StringName) -> Texture2D. Empty = placeholder shapes.
var textures: Dictionary = {}
var selected_id := "":
	set(v):
		if v != selected_id:
			selected_id = v
			queue_redraw()
## Buildings drawn in the last redraw (tests).
var drawn_count := 0

var _visible_tiles := Rect2i()
var _dirty := true


func setup(b: Buildings, inv: Inventory, px: int) -> void:
	buildings = b
	inventory = inv
	tile_px = px
	buildings.buildings_changed.connect(func(_r: Rect2i) -> void: _dirty = true)
	inventory.items_changed.connect(func(_id: String) -> void: _dirty = true)


func set_visible_rect(view: Rect2) -> void:
	var r := Rect2i(Vector2i((view.position / tile_px).floor()) - Vector2i.ONE * 3,
			Vector2i((view.size / tile_px).ceil()) + Vector2i.ONE * 6)
	if r != _visible_tiles:
		_visible_tiles = r
		_dirty = true


func _process(_delta: float) -> void:
	if _dirty:
		_dirty = false
		queue_redraw()


func _draw() -> void:
	drawn_count = 0
	for id in buildings.all_ids():
		var b := buildings.get_building(id)
		var fp := buildings.footprint(b["key"], b["origin"])
		if not _visible_tiles.intersects(fp):
			continue
		drawn_count += 1
		var rect := Rect2(Vector2(fp.position * tile_px), Vector2(fp.size * tile_px))
		_draw_building(b["key"], rect, crate_fill(id, b["key"]))
		if id == selected_id:
			draw_rect(rect.grow(3.0), SELECT_COLOR, false, 3.0)


## 0..1 fill of a crate (inventory kg / def.storage_kg), -1 for non-crates.
func crate_fill(id: String, key: StringName) -> float:
	var d := buildings.def(key)
	if d == null or d.storage_kg <= 0.0:
		return -1.0
	return clampf(inventory.crate_kg(id) / d.storage_kg, 0.0, 1.0)


## The one place a building is drawn (art hook, see class doc).
func _draw_building(key: StringName, rect: Rect2, fill: float = -1.0) -> void:
	var tex := texture_for(key)
	if tex != null:
		draw_texture_rect(tex, rect, false)
		if fill >= 0.0:
			_draw_fill_bar(self, rect, fill)
		return
	draw_shape(self, key, rect, fill)


## Override in `textures`, else production art buildings/building_<key>.png
## (ASSET_SPEC §7), else null (placeholder shape).
func texture_for(key: StringName) -> Texture2D:
	if textures.has(key):
		return textures[key] as Texture2D
	return ArtLibrary.texture(ArtLibrary.building_path(key))


## Building art (production texture or placeholder shape) on any CanvasItem:
## used for order ghosts, the placement preview and build-menu icons.
static func draw_art(ci: CanvasItem, key: StringName, rect: Rect2, alpha: float = 1.0) -> void:
	var tex := ArtLibrary.texture(ArtLibrary.building_path(key))
	if tex != null:
		ci.draw_texture_rect(tex, rect, false, Color(1, 1, 1, alpha))
	else:
		draw_shape(ci, key, rect, -1.0, alpha)


## Placeholder shape of a building key inside rect (any CanvasItem). alpha
## < 1 draws a ghost (orders, icons stay at 1).
static func draw_shape(ci: CanvasItem, key: StringName, rect: Rect2, fill: float = -1.0, alpha: float = 1.0) -> void:
	var u := clampf(minf(rect.size.x, rect.size.y) / 12.0, 1.5, 6.0)  # stroke unit
	var a := func(c: Color) -> Color: return Color(c, c.a * alpha)
	match key:
		&"door":
			ci.draw_rect(rect, a.call(WOOD_DARK))
			var panel := rect.grow(-u * 1.5)
			ci.draw_rect(panel, a.call(WOOD))
			for i in 2:
				var y := panel.position.y + panel.size.y * (0.3 + i * 0.4)
				ci.draw_line(Vector2(panel.position.x, y), Vector2(panel.end.x, y), a.call(WOOD_DARK), maxf(1.0, u * 0.5))
			ci.draw_circle(Vector2(panel.end.x - u * 1.5, panel.position.y + panel.size.y * 0.55), u * 0.8, a.call(METAL))
			ci.draw_rect(rect, a.call(OUTLINE), false, maxf(1.0, u * 0.5))
		&"crate":
			var box := rect.grow(-u * 0.5)
			ci.draw_rect(box, a.call(WOOD))
			for i in range(1, 4):
				var y := box.position.y + box.size.y * i / 4.0
				ci.draw_line(Vector2(box.position.x, y), Vector2(box.end.x, y), a.call(WOOD_DARK), maxf(1.0, u * 0.4))
			ci.draw_line(box.position, box.end, a.call(WOOD_DARK), maxf(1.0, u * 0.6))
			ci.draw_rect(box, a.call(OUTLINE), false, maxf(1.0, u * 0.5))
			if fill >= 0.0:
				_draw_fill_bar(ci, box, fill, alpha)
		&"bed":
			var leg_h := rect.size.y * 0.2
			var base := Rect2(rect.position.x, rect.end.y - rect.size.y * 0.55, rect.size.x, rect.size.y * 0.55 - leg_h)
			ci.draw_rect(Rect2(rect.position.x, rect.position.y + rect.size.y * 0.2, u * 1.2, rect.size.y * 0.8), a.call(WOOD_DARK))
			ci.draw_rect(Rect2(rect.end.x - u * 1.2, rect.end.y - rect.size.y * 0.6, u * 1.2, rect.size.y * 0.6), a.call(WOOD_DARK))
			ci.draw_rect(base, a.call(WOOD))
			ci.draw_rect(Rect2(base.position.x + u * 1.2, base.position.y - u * 1.5, rect.size.x * 0.22, u * 2.0), a.call(PILLOW))
			ci.draw_rect(Rect2(base.position.x + rect.size.x * 0.3, base.position.y - u, rect.size.x * 0.68 - u * 1.2, base.size.y * 0.7 + u), a.call(BLANKET))
			ci.draw_rect(base, a.call(OUTLINE), false, maxf(1.0, u * 0.4))
		&"table":
			var top := Rect2(rect.position.x, rect.position.y + rect.size.y * 0.35, rect.size.x, u * 1.6)
			for x in [rect.position.x + u * 1.5, rect.end.x - u * 3.0]:
				ci.draw_rect(Rect2(x, top.end.y, u * 1.5, rect.end.y - top.end.y), a.call(WOOD_DARK))
			ci.draw_rect(top, a.call(WOOD))
			ci.draw_rect(top, a.call(OUTLINE), false, maxf(1.0, u * 0.4))
		_:
			ci.draw_rect(rect.grow(-2.0), a.call(Color.MAGENTA))


static func _draw_fill_bar(ci: CanvasItem, box: Rect2, fill: float, alpha: float = 1.0) -> void:
	var h := maxf(4.0, box.size.y * 0.1)
	var bar := Rect2(box.position.x + 3.0, box.position.y + 3.0, box.size.x - 6.0, h)
	ci.draw_rect(bar, Color(FILL_BG, FILL_BG.a * alpha))
	ci.draw_rect(Rect2(bar.position, Vector2(bar.size.x * clampf(fill, 0.0, 1.0), h)), Color(FILL_FG, alpha))
