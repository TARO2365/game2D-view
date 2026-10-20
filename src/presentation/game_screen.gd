class_name GameScreen
extends Node2D
## In-game screen for the one loaded world (D-014). Wires presentation nodes
## to the WorldSession and runs the simulation clock and autosave. All game
## state changes go through command methods returning CommandResult; failures
## are shown in the toast.

signal quit_requested

const AUTOSAVE_INTERVAL_SEC := 300.0  # PLACEHOLDER
const TOAST_SECONDS := 3.5
const INSPECTOR_TOP := 190.0  # below the debug HUD. PLACEHOLDER layout

var session: WorldSession
var slots: WorldSlots
var scale_config: ScaleConfig
var load_notice := ""

var world_view: WorldView
var item_view: ItemView
var overlay: DesignationOverlay
var npc_layer: NpcLayer
var tools: ToolController
var camera: CameraController
var speed_bar: SpeedBar
var toolbar: Toolbar
var inspector: NpcInspector
var debug_hud: Label
var toast: Label

var last_tick_ms := 0.0
var autosave_left := AUTOSAVE_INTERVAL_SEC
## Id of the NPC shown in the inspector, "" when none.
var selected_npc_id := ""
## True while "Move here" waits for a world click.
var move_pending := false

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
	var registry := session.grid.registry
	world_view = WorldView.new()
	world_view.name = "WorldView"
	world_view.setup(session.grid, px)
	add_child(world_view)
	item_view = ItemView.new()
	item_view.name = "Items"
	item_view.setup(session.inventory, registry, px)
	add_child(item_view)
	overlay = DesignationOverlay.new()
	overlay.name = "Designations"
	overlay.setup(session.designations, px, session.stockpiles, session.jobs)
	add_child(overlay)
	npc_layer = NpcLayer.new()
	npc_layer.name = "Npcs"
	npc_layer.setup(session.colony, session.inventory, registry, px)
	add_child(npc_layer)
	tools = ToolController.new()
	tools.name = "Tools"
	tools.setup(session, px)
	tools.command_result.connect(_on_command_result)
	tools.tile_clicked.connect(click_tile)
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
	toolbar.priority_selected.connect(set_priority)
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
	inspector = NpcInspector.new()
	inspector.name = "Inspector"
	inspector.setup(session.jobs, session.inventory, registry)
	inspector.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	inspector.offset_left = -NpcInspector.PANEL_WIDTH - 16
	inspector.offset_right = -16
	inspector.offset_top = INSPECTOR_TOP
	inspector.work_toggled.connect(set_work)
	inspector.move_requested.connect(_on_move_button)
	inspector.stop_requested.connect(stop_selected)
	inspector.close_requested.connect(func() -> void: select_npc(""))
	hud.add_child(inspector)
	toast = Label.new()
	toast.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	toast.offset_top = -64
	toast.offset_bottom = -24
	toast.offset_left = -400
	toast.offset_right = 400
	toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast.add_theme_constant_override("outline_size", 5)
	toast.add_theme_color_override("font_outline_color", Color.BLACK)
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
		item_view.set_visible_rect(view)
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
	overlay.show_priorities = t == ToolController.Tool.PRIORITY
	if t != ToolController.Tool.SELECT:
		cancel_move()


func set_priority(p: int) -> CommandResult:
	var r := tools.set_priority(p)
	if r.ok:
		toolbar.set_active_priority(p)
	_on_command_result(r)
	return r


# --- Selection and NPC commands -----------------------------------------

## A click (not a drag) on the world with the Select tool.
func click_tile(tile: Vector2i) -> CommandResult:
	if move_pending:
		return move_selected_to(tile)
	var n := session.colony.npc_at(tile)
	select_npc(n.id if n != null else "")
	return CommandResult.success({"selected": selected_npc_id})


func select_npc(npc_id: String) -> void:
	var n: Npc = session.colony.get_npc(npc_id) if not npc_id.is_empty() else null
	selected_npc_id = n.id if n != null else ""
	move_pending = false
	npc_layer.set_selected(selected_npc_id)
	inspector.show_npc(n)


func selected_npc() -> Npc:
	return session.colony.get_npc(selected_npc_id) if not selected_npc_id.is_empty() else null


## "Move here" button: the next world click becomes the target.
func request_move() -> CommandResult:
	if selected_npc() == null:
		var r := CommandResult.failure(&"no_selection", "Select an NPC first")
		_on_command_result(r)
		return r
	set_tool(ToolController.Tool.SELECT)
	move_pending = true
	inspector.set_move_pending(true)
	show_toast("Click where %s should go (Esc cancels)" % selected_npc().nickname)
	return CommandResult.success()


func cancel_move() -> void:
	if move_pending:
		move_pending = false
		inspector.set_move_pending(false)


func move_selected_to(tile: Vector2i) -> CommandResult:
	cancel_move()
	var r := session.colony.command_move(selected_npc_id, tile)
	_on_command_result(r)
	return r


func stop_selected() -> CommandResult:
	cancel_move()
	var r := session.colony.command_stop(selected_npc_id)
	_on_command_result(r)
	return r


func set_work(work: StringName, on: bool) -> CommandResult:
	var r := session.colony.set_work_enabled(selected_npc_id, work, on)
	_on_command_result(r)
	inspector.refresh()
	return r


## Debug builds only (F10): an extra colonist at the given tile.
func spawn_debug_npc(tile: Vector2i) -> CommandResult:
	if not OS.is_debug_build():
		return CommandResult.failure(&"debug_only", "Spawning NPCs exists only in debug builds")
	if not session.grid.in_bounds(tile):
		return CommandResult.failure(&"out_of_bounds", "Cursor is outside the world")
	var n := session.colony.spawn_npc(tile)
	show_toast("DEV: spawned %s" % n.nickname)
	return CommandResult.success({"npc_id": n.id})


func _on_move_button() -> void:
	if move_pending:
		cancel_move()
	else:
		request_move()


# --- Save / quit ----------------------------------------------------------

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


func _unhandled_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb and mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT and move_pending:
		cancel_move()
		get_viewport().set_input_as_handled()


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if k.keycode == KEY_S and k.ctrl_pressed:
		save_now(SaveService.Kind.MANUAL)
	elif k.keycode == KEY_F9 and OS.is_debug_build():
		var r := tools.set_dev_instant(not tools.dev_instant)
		show_toast("DEV instant edit %s" % ("ON" if tools.dev_instant else "OFF") if r.ok else r.message)
	elif k.keycode == KEY_F10 and OS.is_debug_build():
		_on_command_result(spawn_debug_npc(tools.world_to_tile(get_global_mouse_position())))
	elif k.keycode == KEY_ESCAPE:
		if move_pending:
			cancel_move()
		elif tools.tool == ToolController.Tool.SELECT:
			select_npc("")
		else:
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
		if session.grid.is_ladder(cursor):
			tile_name += " + ladder"
	debug_hud.text = "%s\nFPS %d | tick %d | tick %.2f ms\nchunks drawn %d | orders %d\nNPCs %d | jobs %d\nworld hash %s\ncursor (%d, %d) %s%s" % [
		session.meta.get("name", ""), Engine.get_frames_per_second(), session.clock.tick_index, last_tick_ms,
		world_view.loaded_chunk_count(), session.designations.count(),
		session.colony.count(), session.jobs.job_count(), _hash_cache,
		cursor.x, cursor.y, tile_name, "\nDEV INSTANT EDIT (F9)" if tools.dev_instant else ""]
