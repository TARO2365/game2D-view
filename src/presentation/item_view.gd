class_name ItemView
extends Node2D
## Ground items as small placeholder squares at the bottom of their tile,
## coloured by material; several stacks on one tile form a small pile.
## Visible area only; redrawn when Inventory reports a change.

const ITEM_SIZE_TILES := 0.3      # PLACEHOLDER
const MAX_PILE_SHOWN := 6
const OUTLINE_COLOR := Color(0.05, 0.04, 0.04)

var inventory: Inventory
var registry: TileRegistry
var tile_px := 64

var _visible_tiles := Rect2i()
var _dirty := true
var _colors: Dictionary = {}  # material key -> Color


func setup(inv: Inventory, reg: TileRegistry, px: int) -> void:
	inventory = inv
	registry = reg
	tile_px = px
	for d in reg.all_defs():
		_colors[d.key] = d.placeholder_color
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
			var r := Rect2(base + pile_offset(i, s) - Vector2(s / 2.0, s), Vector2(s, s))
			draw_rect(r, _colors.get(it.material, Color.MAGENTA))
			draw_rect(r, OUTLINE_COLOR, false, 2.0)


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
