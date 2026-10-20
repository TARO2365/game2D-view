class_name CameraController
extends Camera2D
## Pan/zoom within world bounds (spec §9). Mouse: wheel zoom at cursor,
## middle-drag pan (left-drag too while the Select tool is active).
## Keyboard: WASD / arrows. Touch: one-finger drag (Select tool), pinch zoom.
## Zoom limits and speeds are PLACEHOLDERS until the UX prototype.

const ZOOM_MIN := 0.25
const ZOOM_MAX := 2.0
const WHEEL_STEP := 1.15
const PAN_SPEED_PX := 1200.0  # screen pixels per second

var world_size_px := Vector2.ZERO
var left_drag_pans := true

var _dragging := false
var _touches: Dictionary = {}  # touch index -> screen position
var _pinch_dist := 0.0


func setup(world_px: Vector2) -> void:
	world_size_px = world_px


func _process(delta: float) -> void:
	# Shortcuts like Ctrl+S must not also pan the camera.
	if Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_META) or Input.is_key_pressed(KEY_ALT):
		return
	if get_viewport().gui_get_focus_owner() is LineEdit:
		return
	var dir := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT):
		dir.x -= 1
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT):
		dir.x += 1
	if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP):
		dir.y -= 1
	if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN):
		dir.y += 1
	if dir != Vector2.ZERO:
		pan_by(dir.normalized() * PAN_SPEED_PX * delta)


func pan_by(screen_delta: Vector2) -> void:
	position = clamp_center(position + screen_delta / zoom.x, view_size_world(), world_size_px)


func view_size_world() -> Vector2:
	return get_viewport_rect().size / zoom.x


func view_rect_px() -> Rect2:
	var s := view_size_world()
	return Rect2(position - s / 2.0, s)


func screen_to_world(p: Vector2) -> Vector2:
	return position + (p - get_viewport_rect().size / 2.0) / zoom.x


func zoom_by(factor: float, anchor_screen: Vector2) -> void:
	var before := screen_to_world(anchor_screen)
	zoom = Vector2.ONE * clampf(zoom.x * factor, ZOOM_MIN, ZOOM_MAX)
	position += before - screen_to_world(anchor_screen)
	position = clamp_center(position, view_size_world(), world_size_px)


func zoom_by_center(factor: float) -> void:
	zoom_by(factor, get_viewport_rect().size / 2.0)


static func clamp_center(center: Vector2, view: Vector2, world: Vector2) -> Vector2:
	return Vector2(_clamp_axis(center.x, view.x, world.x), _clamp_axis(center.y, view.y, world.y))


static func _clamp_axis(c: float, v: float, w: float) -> float:
	if v >= w:
		return w / 2.0
	return clampf(c, v / 2.0, w - v / 2.0)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if mb.pressed:
					zoom_by(WHEEL_STEP, mb.position)
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					zoom_by(1.0 / WHEEL_STEP, mb.position)
			MOUSE_BUTTON_MIDDLE:
				_dragging = mb.pressed
			MOUSE_BUTTON_LEFT:
				if left_drag_pans or not mb.pressed:
					_dragging = mb.pressed and left_drag_pans
	elif event is InputEventMouseMotion and _dragging:
		pan_by(-(event as InputEventMouseMotion).relative)
	elif event is InputEventMagnifyGesture:
		var g := event as InputEventMagnifyGesture
		zoom_by(g.factor, g.position)
	elif event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		if t.pressed:
			_touches[t.index] = t.position
		else:
			_touches.erase(t.index)
		_pinch_dist = 0.0
	elif event is InputEventScreenDrag:
		var d := event as InputEventScreenDrag
		_touches[d.index] = d.position
		if _touches.size() == 2:
			var pts := _touches.values()
			var dist: float = pts[0].distance_to(pts[1])
			if _pinch_dist > 0.0:
				zoom_by(dist / _pinch_dist, (pts[0] + pts[1]) / 2.0)
			_pinch_dist = dist
