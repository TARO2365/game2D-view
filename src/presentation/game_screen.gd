class_name GameScreen
extends Node2D
## In-game screen for the one loaded world (D-014). Wires presentation nodes
## to the WorldSession and runs the simulation clock and autosave.

signal quit_requested

const AUTOSAVE_INTERVAL_SEC := 300.0  # PLACEHOLDER
const TOAST_SECONDS := 3.5

var session: WorldSession
var slots: WorldSlots
var scale_config: ScaleConfig
var load_notice := ""

var world_view: WorldView
var overlay: DesignationOverlay
var tools: ToolController
var camera: CameraController
var speed_bar: SpeedBar
var toolbar: Toolbar
var debug_hud: Label
var toast: Label

var last_tick_ms := 0.0
var autosave_left := AUTOSAVE_INTERVAL_SEC

var _toast_left := 0.0
var _last_view := Rect2()
var _hash_cache := ""


func setup(s: WorldSession, world_slots: WorldSlots, config: ScaleConfig, notice: String = "") -> void:
	session = s
	slots = world_slots
	scale_config = config
	load_notice = notice


func _ready() -> void:
	var px := scale_config.tile_size_px
	world_view = WorldView.new()
	world_view.name = "WorldView"
	world_view.setup(session.grid, px)
	add_child(world_view)
	overlay = DesignationOverlay.new()
	overlay.name = "Designations"
	overlay.setup(session.designations, px)
	add_child(overlay)
	tools = ToolController.new()
	tools.name = "Tools"
	tools.setup(session, px)
	tools.command_result.connect(_on_command_result)
	add_child(tools)
	camera = CameraController.new()
	camera.name = "Camera"
	camera.setup(Vector2(session.grid.get_size() * px))
	add_child(camera)
	camera.make_current()
	var mid := session.grid.width / 2
	camera.position = CameraController.clamp_center(
			Vector2(mid * px, session.grid.surface_y[mid] * px), camera.view_size_world(), camera.world_size_px)
	session.grid.tiles_changed.connect(func(_r: Rect2i) -> void: _hash_cache = "")

	var hud := CanvasLayer.new()
	hud.name = "HUD"
	add_child(hud)
	var top := VBoxContainer.new()
	top.position = Vector2(16, 16)
	hud.add_child(top)
	speed_bar = SpeedBar.new()
	top.add_child(speed_bar)
	speed_bar.bind_clock(session.clock)
	toolbar = Toolbar.new()
	top.add_child(toolbar)
	toolbar.tool_selected.connect(set_tool)
	toolbar.zoom_requested.connect(func(f: float) -> void: camera.zoom_by_center(f))
	toolbar.save_requested.connect(func() -> void: save_now(SaveService.Kind.MANUAL))
	toolbar.menu_requested.connect(quit_to_menu)
	debug_hud = Label.new()
	debug_hud.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	debug_hud.offset_left = -360
	debug_hud.offset_right = -16
	debug_hud.offset_top = 16
	debug_hud.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hud.add_child(debug_hud)
	toast = Label.new()
	toast.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	toast.offset_top = -64
	toast.offset_bottom = -24
	toast.offset_left = -400
	toast.offset_right = 400
	toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud.add_child(toast)
	set_tool(ToolController.Tool.SELECT)
	if not load_notice.is_empty():
		show_toast(load_notice)


func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	session.clock.advance(delta)
	last_tick_ms = (Time.get_ticks_usec() - t0) / 1000.0
	var view := camera.view_rect_px()
	if view != _last_view:
		_last_view = view
		world_view.update_visible(view)
		overlay.set_visible_rect(view)
	autosave_left -= delta
	if autosave_left <= 0.0:
		autosave_left = AUTOSAVE_INTERVAL_SEC
		save_now(SaveService.Kind.AUTO)
	if _toast_left > 0.0:
		_toast_left -= delta
		if _toast_left <= 0.0:
			toast.text = ""
	_update_hud()


func set_tool(t: int) -> void:
	tools.set_tool(t)
	camera.left_drag_pans = t == ToolController.Tool.SELECT
	toolbar.set_active_tool(t)


## Saves happen in _process, i.e. between simulation ticks (coherent state).
func save_now(kind: SaveService.Kind) -> CommandResult:
	var r := SaveService.save(session, slots.world_dir(session.world_id()), kind)
	if r.ok:
		session.meta["last_played_unix"] = Time.get_unix_time_from_system()
		slots.write_meta(session.meta)
		show_toast("Autosaved" if kind == SaveService.Kind.AUTO else "Saved")
	else:
		show_toast("Save failed: %s" % r.message)
	return r


func quit_to_menu() -> void:
	save_now(SaveService.Kind.AUTO)
	quit_requested.emit()


func show_toast(text: String) -> void:
	toast.text = text
	_toast_left = TOAST_SECONDS


func _on_command_result(r: CommandResult) -> void:
	if not r.ok:
		show_toast(r.message)


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if k.keycode == KEY_S and k.ctrl_pressed:
		save_now(SaveService.Kind.MANUAL)
	elif k.keycode == KEY_F9 and OS.is_debug_build():
		var r := tools.set_dev_instant(not tools.dev_instant)
		show_toast("DEV instant edit %s" % ("ON" if tools.dev_instant else "OFF") if r.ok else r.message)
	elif k.keycode == KEY_ESCAPE:
		set_tool(ToolController.Tool.SELECT)
	else:
		return
	get_viewport().set_input_as_handled()


func _update_hud() -> void:
	if _hash_cache.is_empty():
		_hash_cache = session.grid.world_hash().left(12)
	var cursor := tools.world_to_tile(get_global_mouse_position())
	var tile_name := "-"
	if session.grid.in_bounds(cursor):
		tile_name = session.grid.registry.get_def(session.grid.get_tile(cursor)).display_name
	debug_hud.text = "%s\nFPS %d | tick %d | tick %.2f ms\nchunks drawn %d | orders %d\nworld hash %s\ncursor (%d, %d) %s%s" % [
		session.meta.get("name", ""), Engine.get_frames_per_second(), session.clock.tick_index, last_tick_ms,
		world_view.loaded_chunk_count(), session.designations.count(), _hash_cache,
		cursor.x, cursor.y, tile_name, "\nDEV INSTANT EDIT (F9)" if tools.dev_instant else ""]
