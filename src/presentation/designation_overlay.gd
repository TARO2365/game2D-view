class_name DesignationOverlay
extends Node2D
## Draws player orders (dig / build wall / build ladder / deconstruct, hatched),
## pending building orders (ghosts) and stockpile zones on top of terrain, visible area only. Orders no NPC can reach are tinted
## red; priority numbers are shown while the Priority tool is active.

const DIG_FILL := Color(1.0, 0.62, 0.15, 0.3)
const DIG_EDGE := Color(1.0, 0.7, 0.2, 0.9)
const BUILD_FILL := Color(0.3, 0.8, 1.0, 0.3)
const BUILD_EDGE := Color(0.4, 0.85, 1.0, 0.9)
const LADDER_FILL := Color(0.95, 0.85, 0.3, 0.25)
const LADDER_EDGE := Color(1.0, 0.9, 0.35, 0.95)
const UNREACHABLE_FILL := Color(1.0, 0.1, 0.1, 0.35)
const UNREACHABLE_EDGE := Color(1.0, 0.25, 0.25, 1.0)
const DECON_FILL := Color(1.0, 0.35, 0.1, 0.25)
const DECON_EDGE := Color(1.0, 0.42, 0.15, 0.95)
const ORDER_FILL := Color(0.75, 0.4, 1.0, 0.12)
const ORDER_EDGE := Color(0.8, 0.5, 1.0, 0.95)
const GHOST_ALPHA := 0.45
const STOCKPILE_FILL := Color(0.3, 0.9, 0.35, 0.16)
const STOCKPILE_EDGE := Color(0.35, 0.95, 0.4, 0.8)
const PRIORITY_FONT_SIZE := 22
## Unreachable flags change without a signal: re-check this often. PLACEHOLDER.
const POLL_SECONDS := 0.5

var designations: DesignationMap
var stockpiles: StockpileZones
var jobs: JobManager
var build_orders: BuildOrders
var tile_px := 64
var show_priorities := false:
	set(v):
		if v != show_priorities:
			show_priorities = v
			queue_redraw()
## Order tiles drawn as unreachable in the last redraw (tests / HUD).
var unreachable_drawn := 0

var _visible_tiles := Rect2i()
var _poll_left := POLL_SECONDS


func setup(map: DesignationMap, px: int, zones: StockpileZones = null, job_manager: JobManager = null) -> void:
	designations = map
	stockpiles = zones
	jobs = job_manager
	tile_px = px
	designations.designations_changed.connect(func(_r: Rect2i) -> void: queue_redraw())
	if stockpiles:
		stockpiles.zones_changed.connect(func(_r: Rect2i) -> void: queue_redraw())
	if jobs:
		jobs.jobs_changed.connect(queue_redraw)


func set_build_orders(orders: BuildOrders) -> void:
	build_orders = orders
	build_orders.orders_changed.connect(func(_r: Rect2i) -> void: queue_redraw())


func set_visible_rect(view: Rect2) -> void:
	var r := Rect2i(Vector2i((view.position / tile_px).floor()) - Vector2i.ONE,
			Vector2i((view.size / tile_px).ceil()) + Vector2i.ONE * 3)
	if r != _visible_tiles:
		_visible_tiles = r
		queue_redraw()


func _process(delta: float) -> void:
	_poll_left -= delta
	if _poll_left <= 0.0:
		_poll_left = POLL_SECONDS
		if jobs and (designations.count() > 0 or (build_orders != null and build_orders.count() > 0)):
			queue_redraw()


func _draw() -> void:
	_draw_stockpiles()
	var w := designations.grid.width
	var entries := designations.entries()
	var font: Font = ThemeDB.fallback_font  # digits only
	unreachable_drawn = 0
	for idx in entries:
		var p := Vector2i(idx % w, idx / w)
		if not _visible_tiles.has_point(p):
			continue
		var rect := Rect2(Vector2(p * tile_px) + Vector2(3, 3), Vector2(tile_px - 6, tile_px - 6))
		var fill := BUILD_FILL
		var edge := BUILD_EDGE
		match entries[idx]:
			DesignationMap.Kind.DIG:
				fill = DIG_FILL
				edge = DIG_EDGE
			DesignationMap.Kind.BUILD_LADDER:
				fill = LADDER_FILL
				edge = LADDER_EDGE
			DesignationMap.Kind.DECONSTRUCT:
				fill = DECON_FILL
				edge = DECON_EDGE
		draw_rect(rect, fill)
		if entries[idx] == DesignationMap.Kind.DECONSTRUCT:
			_draw_hatch(rect, DECON_EDGE)
		if entries[idx] == DesignationMap.Kind.BUILD_LADDER:
			draw_line(rect.position + Vector2(rect.size.x * 0.3, 0), rect.position + Vector2(rect.size.x * 0.3, rect.size.y), edge, 2.0)
			draw_line(rect.position + Vector2(rect.size.x * 0.7, 0), rect.position + Vector2(rect.size.x * 0.7, rect.size.y), edge, 2.0)
		if jobs and jobs.is_unreachable(p):
			unreachable_drawn += 1
			draw_rect(rect, UNREACHABLE_FILL)
			edge = UNREACHABLE_EDGE
		draw_rect(rect, edge, false, 2.0)
		if show_priorities:
			var text := str(designations.get_priority(p))
			var pos := rect.position + Vector2(0, rect.size.y / 2.0 + PRIORITY_FONT_SIZE * 0.35)
			draw_string_outline(font, pos, text, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, PRIORITY_FONT_SIZE, 4, Color.BLACK)
			draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, PRIORITY_FONT_SIZE, Color.WHITE)
	_draw_build_orders(font)


## Pending building orders: ghost of the building + outline in ORDER_EDGE.
func _draw_build_orders(font: Font) -> void:
	if build_orders == null or build_orders.count() == 0:
		return
	for o in build_orders.orders():
		var fp := build_orders.footprint_of(o["id"])
		if not _visible_tiles.intersects(fp):
			continue
		var rect := Rect2(Vector2(fp.position * tile_px), Vector2(fp.size * tile_px)).grow(-2.0)
		draw_rect(rect, ORDER_FILL)
		BuildingView.draw_shape(self, o["key"], rect, -1.0, GHOST_ALPHA)
		var edge := ORDER_EDGE
		if jobs and jobs.is_unreachable(o["origin"]):
			unreachable_drawn += 1
			draw_rect(rect, UNREACHABLE_FILL)
			edge = UNREACHABLE_EDGE
		draw_rect(rect, edge, false, 3.0)
		if show_priorities:
			var text := str(o["priority"])
			var pos := Vector2(rect.position.x, rect.end.y - tile_px / 2.0 + PRIORITY_FONT_SIZE * 0.35)
			draw_string_outline(font, pos, text, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, PRIORITY_FONT_SIZE, 4, Color.BLACK)
			draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, PRIORITY_FONT_SIZE, Color.WHITE)


## Diagonal hatch for deconstruct orders.
func _draw_hatch(rect: Rect2, col: Color) -> void:
	var step := rect.size.x / 4.0
	for i in range(1, 8):
		var d := i * step
		var a := rect.position + Vector2(minf(d, rect.size.x), maxf(0.0, d - rect.size.x))
		var b := rect.position + Vector2(maxf(0.0, d - rect.size.y), minf(d, rect.size.y))
		draw_line(a, b, col, 2.0)


func _draw_stockpiles() -> void:
	if stockpiles == null or stockpiles.count() == 0:
		return
	for t in stockpiles.tiles():
		if not _visible_tiles.has_point(t):
			continue
		var rect := Rect2(Vector2(t * tile_px) + Vector2(1, 1), Vector2(tile_px - 2, tile_px - 2))
		draw_rect(rect, STOCKPILE_FILL)
		draw_rect(rect, STOCKPILE_EDGE, false, 2.0)
