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

enum Tool { SELECT, DIG, BUILD, CANCEL, LADDER, STOCKPILE, CLEAR_STOCKPILE, PRIORITY }

const SELECTION_COLOR := Color(1, 1, 1, 0.9)
## Pointer travel (screen px) below which a press/release counts as a click. PLACEHOLDER.
const CLICK_SLOP_PX := 8.0

var tool: Tool = Tool.SELECT
var dev_instant := false
## Priority used by the Priority tool and for new Dig/Wall/Ladder orders.
var priority := DesignationMap.DEFAULT_PRIORITY
var session: WorldSession
var tile_px := 64

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
	queue_redraw()


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
	return t == Tool.DIG or t == Tool.BUILD or t == Tool.LADDER


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
			r = session.designations.set_priority(rect, priority)
		Tool.CANCEL:
			r = session.designations.cancel(rect)
		_:
			r = CommandResult.failure(&"no_tool", "Choose an order tool first")
	command_result.emit(r)
	return r


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


func _draw() -> void:
	if not _dragging:
		return
	var r := rect_from_tiles(_start, _end)
	draw_rect(Rect2(Vector2(r.position * tile_px), Vector2(r.size * tile_px)), SELECTION_COLOR, false, 2.0)
