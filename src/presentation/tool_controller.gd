class_name ToolController
extends Node2D
## Turns pointer drags into validated commands (spec §9: UI issues commands,
## never edits state itself). In normal play Dig/Build/Ladder only place
## designations (D-015). The debug-build-only "instant edit" mode applies
## terrain edits / structures directly so edit/render/save paths can be tested.
## With the Select tool a click (press + release without moving) emits
## tile_clicked; drags are left to the camera (pan).

signal command_result(result: CommandResult)
signal tile_clicked(tile: Vector2i)

signal cancel_requested

enum Tool { SELECT, DIG, BUILD, CANCEL, LADDER, STOCKPILE, CLEAR_STOCKPILE, PRIORITY, DECONSTRUCT, PLACE_BUILDING }

const SELECTION_COLOR := Color(1, 1, 1, 0.9)
const PREVIEW_OK := Color(0.3, 1.0, 0.4)
const PREVIEW_BAD := Color(1.0, 0.25, 0.2)
## Pointer travel (screen px) below which a press/release counts as a click. PLACEHOLDER.
const CLICK_SLOP_PX := 8.0

var tool: Tool = Tool.SELECT
var dev_instant := false
## Priority used by the Priority tool and for new Dig/Wall/Ladder orders.
var priority := DesignationMap.DEFAULT_PRIORITY
var session: WorldSession
var tile_px := 64
## Building key placed by Tool.PLACE_BUILDING (set via start_placement).
var place_key: StringName = &""
## Placement preview: origin (bottom-left tile) under the pointer and its check.
var preview_origin := Vector2i(-1, -1)
var preview_result: CommandResult

var _dragging := false
var _start := Vector2i.ZERO
var _end := Vector2i.ZERO
var _click_down := false
var _click_travel := 0.0


func setup(s: WorldSession, px: int) -> void:
	session = s
	tile_px = px


func set_tool(t: Tool) -> void:
	tool = t
	_dragging = false
	_click_down = false
	if t != Tool.PLACE_BUILDING:
		place_key = &""
	preview_origin = Vector2i(-1, -1)
	preview_result = null
	queue_redraw()


## Enters building placement mode for a BuildingDef key.
func start_placement(key: StringName) -> CommandResult:
	if session.buildings.def(key) == null:
		return CommandResult.failure(&"unknown_key", "Unknown building '%s'" % key)
	set_tool(Tool.PLACE_BUILDING)
	place_key = key
	return CommandResult.success({"key": key})


## Read-only placement check (same rules BuildOrders.order_building applies:
## Buildings.can_place, then no overlap with other orders / designations).
func check_placement(key: StringName, origin: Vector2i) -> CommandResult:
	var r := session.buildings.can_place(key, origin)
	if not r.ok:
		return r
	var fp := session.buildings.footprint(key, origin)
	for y in range(fp.position.y, fp.end.y):
		for x in range(fp.position.x, fp.end.x):
			var p := Vector2i(x, y)
			if not session.build_orders.order_at(p).is_empty():
				return CommandResult.failure(&"overlaps_order", "Another building is ordered there", {"tile": p})
			if session.designations.get_kind(p) != DesignationMap.Kind.NONE:
				return CommandResult.failure(&"overlaps_designation", "Another order is on that tile", {"tile": p})
	return r


## Moves the preview to origin (cached: recomputed only when origin changes).
func update_preview(origin: Vector2i) -> CommandResult:
	if origin != preview_origin or preview_result == null:
		preview_origin = origin
		preview_result = check_placement(place_key, origin)
		queue_redraw()
	return preview_result


## Places a building order at origin (the click of the placement tool).
func place_at(origin: Vector2i) -> CommandResult:
	var r: CommandResult
	if place_key.is_empty():
		r = CommandResult.failure(&"no_building", "Choose a building in the Build menu first")
	else:
		r = session.build_orders.order_building(place_key, origin, priority)
	preview_result = null  # the spot is taken now: re-check
	if not place_key.is_empty():
		update_preview(origin)
	command_result.emit(r)
	return r


func set_priority(p: int) -> CommandResult:
	if p < DesignationMap.MIN_PRIORITY or p > DesignationMap.MAX_PRIORITY:
		return CommandResult.failure(&"invalid_priority",
				"Priority must be %d-%d" % [DesignationMap.MIN_PRIORITY, DesignationMap.MAX_PRIORITY])
	priority = p
	return CommandResult.success({"priority": p})


func set_dev_instant(on: bool) -> CommandResult:
	if on and not OS.is_debug_build():
		return CommandResult.failure(&"debug_only", "Instant edit exists only in debug builds")
	dev_instant = on
	return CommandResult.success({"dev_instant": on})


func world_to_tile(p: Vector2) -> Vector2i:
	return Vector2i(floori(p.x / tile_px), floori(p.y / tile_px))


static func rect_from_tiles(a: Vector2i, b: Vector2i) -> Rect2i:
	var lo := Vector2i(mini(a.x, b.x), mini(a.y, b.y))
	var hi := Vector2i(maxi(a.x, b.x), maxi(a.y, b.y))
	return Rect2i(lo, hi - lo + Vector2i.ONE)


## True for tools that create new orders (they use `priority`).
static func is_order_tool(t: int) -> bool:
	return t in [Tool.DIG, Tool.BUILD, Tool.LADDER, Tool.DECONSTRUCT, Tool.PLACE_BUILDING]


func apply_rect(rect: Rect2i) -> CommandResult:
	var r: CommandResult
	match tool:
		Tool.DIG:
			if dev_instant:
				r = session.grid.apply_edit(rect, WorldGrid.Edit.DIG)
			else:
				r = session.designations.designate(rect, DesignationMap.Kind.DIG, priority)
		Tool.BUILD:
			if dev_instant:
				r = session.grid.apply_edit(rect, WorldGrid.Edit.BUILD_WALL)
			else:
				r = session.designations.designate(rect, DesignationMap.Kind.BUILD_WALL, priority)
		Tool.LADDER:
			if dev_instant:
				r = _place_ladders_now(rect)
			else:
				r = session.designations.designate(rect, DesignationMap.Kind.BUILD_LADDER, priority)
		Tool.STOCKPILE:
			r = session.stockpiles.designate(rect)
		Tool.CLEAR_STOCKPILE:
			r = session.stockpiles.remove(rect)
		Tool.PRIORITY:
			r = _both(session.designations.set_priority(rect, priority),
					session.build_orders.set_priority(rect, priority), "changed")
		Tool.CANCEL:
			r = _both(session.designations.cancel(rect), session.build_orders.cancel_at(rect), "removed")
		Tool.DECONSTRUCT:
			r = session.designations.designate(rect, DesignationMap.Kind.DECONSTRUCT, priority)
		_:
			r = CommandResult.failure(&"no_tool", "Choose an order tool first")
	command_result.emit(r)
	return r


## Tile orders and building orders together: success if either changed
## something (data[count_key] = sum); otherwise the tile-order failure.
static func _both(tiles: CommandResult, blds: CommandResult, count_key: String) -> CommandResult:
	if not tiles.ok and not blds.ok:
		return tiles
	var n := int(tiles.data.get(count_key, 0)) + int(blds.data.get(count_key, 0))
	return CommandResult.success({count_key: n, "tiles": tiles.data.get(count_key, 0),
			"buildings": blds.data.get(count_key, 0)})


## Debug instant edit: WorldGrid.apply_structure on every valid tile.
func _place_ladders_now(rect: Rect2i) -> CommandResult:
	var r := rect.intersection(session.grid.bounds())
	var placed := 0
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var p := Vector2i(x, y)
			if session.grid.can_place_structure(p, WorldGrid.Structure.LADDER):
				if session.grid.apply_structure(p, WorldGrid.Structure.LADDER).ok:
					placed += 1
	if placed == 0:
		return CommandResult.failure(&"nothing_to_change", "No open tile for a ladder in the selection")
	return CommandResult.success({"placed": placed})


func _unhandled_input(event: InputEvent) -> void:
	if tool == Tool.SELECT:
		_select_input(event)
		return
	if tool == Tool.PLACE_BUILDING:
		_place_input(event)
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed and _dragging:
			_dragging = false  # right-click aborts the drag
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			var t := world_to_tile(get_global_mouse_position())
			if mb.pressed:
				_dragging = true
				_start = t
				_end = t
			elif _dragging:
				_dragging = false
				_end = t
				apply_rect(rect_from_tiles(_start, _end))
		else:
			return
		queue_redraw()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _dragging:
		_end = world_to_tile(get_global_mouse_position())
		queue_redraw()
		get_viewport().set_input_as_handled()


## Click detection only; the event is not consumed so the camera still pans.
func _select_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			_click_down = true
			_click_travel = 0.0
		elif _click_down:
			_click_down = false
			if _click_travel <= CLICK_SLOP_PX:
				tile_clicked.emit(world_to_tile(get_global_mouse_position()))
	elif event is InputEventMouseMotion and _click_down:
		_click_travel += (event as InputEventMouseMotion).relative.length()


## Placement mode: preview follows the pointer, left click orders, right
## click exits (GameScreen switches back to Select).
func _place_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		update_preview(world_to_tile(get_global_mouse_position()))
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if not mb.pressed:
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			place_at(world_to_tile(get_global_mouse_position()))
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			cancel_requested.emit()
		else:
			return
		get_viewport().set_input_as_handled()


func _draw() -> void:
	if tool == Tool.PLACE_BUILDING and preview_result != null and not place_key.is_empty():
		var fp := session.buildings.footprint(place_key, preview_origin)
		var rect := Rect2(Vector2(fp.position * tile_px), Vector2(fp.size * tile_px))
		var col := PREVIEW_OK if preview_result.ok else PREVIEW_BAD
		draw_rect(rect, Color(col, 0.25))
		BuildingView.draw_shape(self, place_key, rect, -1.0, 0.55)
		draw_rect(rect, col, false, 3.0)
		return
	if not _dragging:
		return
	var r := rect_from_tiles(_start, _end)
	draw_rect(Rect2(Vector2(r.position * tile_px), Vector2(r.size * tile_px)), SELECTION_COLOR, false, 2.0)
