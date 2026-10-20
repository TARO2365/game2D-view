class_name ToolController
extends Node2D
## Turns pointer drags into validated commands (spec §9: UI issues commands,
## never edits state itself). In normal play Dig/Build only place
## designations (D-015). The debug-build-only "instant edit" mode applies
## terrain edits directly so M1 can test edit/render/save paths.

signal command_result(result: CommandResult)

enum Tool { SELECT, DIG, BUILD, CANCEL }

const SELECTION_COLOR := Color(1, 1, 1, 0.9)

var tool: Tool = Tool.SELECT
var dev_instant := false
var session: WorldSession
var tile_px := 64

var _dragging := false
var _start := Vector2i.ZERO
var _end := Vector2i.ZERO


func setup(s: WorldSession, px: int) -> void:
	session = s
	tile_px = px


func set_tool(t: Tool) -> void:
	tool = t
	_dragging = false
	queue_redraw()


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


func apply_rect(rect: Rect2i) -> CommandResult:
	var r: CommandResult
	match tool:
		Tool.DIG:
			if dev_instant:
				r = session.grid.apply_edit(rect, WorldGrid.Edit.DIG)
			else:
				r = session.designations.designate(rect, DesignationMap.Kind.DIG)
		Tool.BUILD:
			if dev_instant:
				r = session.grid.apply_edit(rect, WorldGrid.Edit.BUILD_WALL)
			else:
				r = session.designations.designate(rect, DesignationMap.Kind.BUILD_WALL)
		Tool.CANCEL:
			r = session.designations.cancel(rect)
		_:
			r = CommandResult.failure(&"no_tool", "Choose Dig, Build or Cancel first")
	command_result.emit(r)
	return r


func _unhandled_input(event: InputEvent) -> void:
	if tool == Tool.SELECT:
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


func _draw() -> void:
	if not _dragging:
		return
	var r := rect_from_tiles(_start, _end)
	draw_rect(Rect2(Vector2(r.position * tile_px), Vector2(r.size * tile_px)), SELECTION_COLOR, false, 2.0)
