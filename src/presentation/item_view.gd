class_name ItemView
extends Node2D
## Ground items at the bottom of their tile: one item per stack (production
## icon from ArtLibrary when present, else ItemArt: chunks, food shapes),
## several stacks on one tile form a small pile. Visible area only; redrawn
## when Inventory reports a change.

const ITEM_SIZE_TILES := 0.3      # PLACEHOLDER
const MAX_PILE_SHOWN := 6
const OUTLINE_COLOR := Color(0.05, 0.04, 0.04)
const SPARKLE := {&"iron_ore": true, &"gold_ore": true, &"crystal": true}

var inventory: Inventory
var registry: TileRegistry
var tile_px := 64

var _visible_tiles := Rect2i()
var _dirty := true
var _colors: Dictionary = {}  # material key -> Color
var _icons: Dictionary = {}   # material key -> Texture2D or null


func setup(inv: Inventory, reg: TileRegistry, px: int) -> void:
	inventory = inv
	registry = reg
	tile_px = px
	# Every item material (MaterialDefs: soil, ore, food) plus tile keys.
	var keys: Array[StringName] = []
	for d in reg.all_defs():
		keys.append(d.key)
	var mats := ItemArt.materials()
	if mats:
		for k in mats.all_keys():
			if not k in keys:
				keys.append(k)
	for k in keys:
		_colors[k] = NpcView.material_art_color(reg, k)
		_icons[k] = ArtLibrary.item_texture(k)
	inventory.items_changed.connect(func(_id: String) -> void: _dirty = true)


func set_visible_rect(view: Rect2) -> void:
	var r := Rect2i(Vector2i((view.position / tile_px).floor()) - Vector2i.ONE,
			Vector2i((view.size / tile_px).ceil()) + Vector2i.ONE * 3)
	if r != _visible_tiles:
		_visible_tiles = r
		_dirty = true


func _process(_delta: float) -> void:
	if _dirty:
		_dirty = false
		queue_redraw()


## Visible ground stacks grouped by tile: Vector2i -> Array[ItemStack].
func visible_piles() -> Dictionary:
	var piles: Dictionary = {}
	for it in inventory.all_items():
		if it.holder != Inventory.Holder.GROUND or not _visible_tiles.has_point(it.tile):
			continue
		if not piles.has(it.tile):
			piles[it.tile] = []
		piles[it.tile].append(it)
	return piles


func _draw() -> void:
	var s := ITEM_SIZE_TILES * tile_px
	var piles := visible_piles()
	for t: Vector2i in piles:
		var stacks: Array = piles[t]
		var base := Vector2((t.x + 0.5) * tile_px, (t.y + 1) * tile_px)
		for i in mini(stacks.size(), MAX_PILE_SHOWN):
			var it: ItemStack = stacks[i]
			var bottom := base + pile_offset(i, s)
			var icon: Texture2D = _icons.get(it.material)
			if icon != null:
				draw_texture_rect(icon, Rect2(bottom - Vector2(s / 2.0, s), Vector2(s, s)), false)
				continue
			var c := bottom - Vector2(0, s * 0.42)
			var col: Color = _colors.get(it.material, ItemArt.color_for(registry, it.material))
			ItemArt.draw(self, it.material, c, s * 0.5, col, t.x * 31 + t.y * 17 + i)
			if SPARKLE.has(it.material):
				var sp := c + Vector2(s * 0.12, -s * 0.12)
				draw_line(sp - Vector2(s * 0.14, 0), sp + Vector2(s * 0.14, 0), Color(1, 1, 0.9, 0.9), 1.5)
				draw_line(sp - Vector2(0, s * 0.14), sp + Vector2(0, s * 0.14), Color(1, 1, 0.9, 0.9), 1.5)


## Offset (bottom-centre) of the i-th stack in a pile: 3 on the floor, then
## 2 on top, then 1 (a small pyramid).
static func pile_offset(i: int, size: float) -> Vector2:
	var rows := [[-1.0, 0.0, 1.0], [-0.5, 0.5], [0.0]]
	var k := i % MAX_PILE_SHOWN
	for row in rows.size():
		var cols: Array = rows[row]
		if k < cols.size():
			return Vector2(cols[k] * size, -row * size)
		k -= cols.size()
	return Vector2.ZERO
