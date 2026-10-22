class_name GameScreen
extends Node2D
## In-game screen for the one loaded world (D-014). Wires presentation nodes
## to the WorldSession and runs the simulation clock and autosave. All game
## state changes go through command methods returning CommandResult; failures
## are shown in the toast.

signal quit_requested

const AUTOSAVE_INTERVAL_SEC := 300.0  # PLACEHOLDER
const TOAST_SECONDS := 3.5
## Layout at 1280×720 (PLACEHOLDER): left column = speed/clock, toolbar, then
## build menu OR colony overview; bottom-left = debug HUD; right column =
## alerts, then NPC / building inspector; schedule editor bottom-centre.
const INSPECTOR_TOP := 200.0
const DEBUG_HUD_WIDTH := 340.0
const DEBUG_HUD_HEIGHT := 84.0
const SCHEDULE_POS := Vector2(372, 352)
## Day/night tint keyframes [hour, colour], piecewise linear over the day
## (dusk 18–20, night 20–05, dawn 05–07). Night stays light enough to read
## underground (one global tint, no per-depth cost). PLACEHOLDER colours.
const TINT_DAY := Color(1, 1, 1)
const TINT_NIGHT := Color(0.52, 0.56, 0.8)
const TINT_KEYS := [
	[0.0, TINT_NIGHT], [5.0, TINT_NIGHT], [6.0, Color(0.95, 0.82, 0.78)], [7.0, TINT_DAY],
	[18.0, TINT_DAY], [19.0, Color(1.0, 0.8, 0.68)], [20.0, TINT_NIGHT], [24.0, TINT_NIGHT],
]

var session: WorldSession
var slots: WorldSlots
var scale_config: ScaleConfig
var load_notice := ""

var world_view: WorldView
var building_view: BuildingView
var item_view: ItemView
var overlay: DesignationOverlay
var room_overlay: RoomOverlay
var npc_layer: NpcLayer
var tools: ToolController
var camera: CameraController
var speed_bar: SpeedBar
var toolbar: Toolbar
var inspector: NpcInspector
var building_inspector: BuildingInspector
var build_menu: BuildMenu
var clock_view: ClockView
var alerts_panel: AlertsPanel
var overview: ColonyOverview
var schedule_editor: ScheduleEditor
var debug_hud: Label
var toast: Label
## Day/night tint of the world canvas (M4A-QA-5). HUD CanvasLayers are not affected.
var day_tint: CanvasModulate

var last_tick_ms := 0.0
var autosave_left := AUTOSAVE_INTERVAL_SEC
## Id of the NPC shown in the inspector, "" when none.
var selected_npc_id := ""
## Id of the building shown in the building inspector, "" when none.
var selected_building_id := ""
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
	building_view = BuildingView.new()
	building_view.name = "Buildings"
	building_view.setup(session.buildings, session.inventory, px)
	add_child(building_view)
	room_overlay = RoomOverlay.new()
	room_overlay.name = "Rooms"
	room_overlay.setup(session.rooms, px)
	add_child(room_overlay)
	item_view = ItemView.new()
	item_view.name = "Items"
	item_view.setup(session.inventory, registry, px)
	add_child(item_view)
	overlay = DesignationOverlay.new()
	overlay.name = "Designations"
	overlay.setup(session.designations, px, session.stockpiles, session.jobs)
	overlay.set_build_orders(session.build_orders)
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
	tools.cancel_requested.connect(func() -> void: set_tool(ToolController.Tool.SELECT))
	add_child(tools)
	camera = CameraController.new()
	camera.name = "Camera"
	camera.setup(Vector2(session.grid.get_size() * px))
	add_child(camera)
	camera.make_current()
	day_tint = CanvasModulate.new()
	day_tint.name = "DayNightTint"
	day_tint.color = tint_for_tick(session.clock.tick_index)
	add_child(day_tint)
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
	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 12)
	top.add_child(top_row)
	speed_bar = SpeedBar.new()
	top_row.add_child(speed_bar)
	speed_bar.bind_clock(session.clock)
	clock_view = ClockView.new()
	clock_view.name = "Clock"
	clock_view.bind_clock(session.clock)
	top_row.add_child(clock_view)
	toolbar = Toolbar.new()
	top.add_child(toolbar)
	toolbar.tool_selected.connect(set_tool)
	toolbar.build_menu_requested.connect(open_build_menu)
	toolbar.rooms_toggled.connect(set_rooms_visible)
	toolbar.colony_toggled.connect(set_overview_visible)
	toolbar.priority_selected.connect(set_priority)
	toolbar.zoom_requested.connect(func(f: float) -> void: camera.zoom_by_center(f))
	toolbar.save_requested.connect(func() -> void: save_now(SaveService.Kind.MANUAL))
	toolbar.menu_requested.connect(quit_to_menu)
	build_menu = BuildMenu.new()
	build_menu.name = "BuildMenu"
	build_menu.setup(session.buildings.registry.all_defs(), registry)
	build_menu.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	build_menu.visible = false
	build_menu.building_chosen.connect(start_placement)
	build_menu.close_requested.connect(close_build_menu)
	top.add_child(build_menu)
	overview = ColonyOverview.new()
	overview.name = "ColonyOverview"
	overview.setup(session.colony, session.inventory, session.materials)
	overview.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	overview.visible = false
	overview.npc_clicked.connect(func(id: String) -> void: focus_npc(id))
	overview.close_requested.connect(func() -> void: set_overview_visible(false))
	top.add_child(overview)
	# Debug HUD: compact, bottom-left (the right column holds alerts + inspectors).
	debug_hud = Label.new()
	debug_hud.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	debug_hud.offset_left = 16
	debug_hud.offset_right = 16 + DEBUG_HUD_WIDTH
	debug_hud.offset_top = -DEBUG_HUD_HEIGHT - 8
	debug_hud.offset_bottom = -8
	debug_hud.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	debug_hud.add_theme_font_size_override("font_size", 12)
	debug_hud.add_theme_constant_override("outline_size", 4)
	debug_hud.add_theme_color_override("font_outline_color", Color.BLACK)
	debug_hud.add_theme_color_override("font_color", Color(1, 1, 1, 0.8))
	hud.add_child(debug_hud)
	alerts_panel = AlertsPanel.new()
	alerts_panel.name = "Alerts"
	alerts_panel.setup(session.alerts)
	alerts_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	alerts_panel.offset_left = -AlertsPanel.PANEL_WIDTH - 16
	alerts_panel.offset_right = -16
	alerts_panel.offset_top = 16
	alerts_panel.alert_clicked.connect(focus_alert)
	hud.add_child(alerts_panel)
	schedule_editor = ScheduleEditor.new()
	schedule_editor.name = "Schedule"
	schedule_editor.position = SCHEDULE_POS
	schedule_editor.visible = false
	schedule_editor.schedule_changed.connect(set_selected_schedule)
	schedule_editor.apply_all_requested.connect(set_schedule_all)
	schedule_editor.close_requested.connect(func() -> void: set_schedule_visible(false))
	hud.add_child(schedule_editor)
	inspector = NpcInspector.new()
	inspector.name = "Inspector"
	inspector.setup(session.jobs, session.inventory, registry, session.buildings, session.colony)
	inspector.materials = session.materials
	inspector.bed_selected.connect(assign_bed)
	inspector.schedule_requested.connect(func() -> void: set_schedule_visible(not schedule_editor.visible))
	inspector.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	inspector.offset_left = -NpcInspector.PANEL_WIDTH - 16
	inspector.offset_right = -16
	inspector.offset_top = INSPECTOR_TOP
	inspector.work_toggled.connect(set_work)
	inspector.move_requested.connect(_on_move_button)
	inspector.stop_requested.connect(stop_selected)
	inspector.close_requested.connect(func() -> void: select_npc(""))
	hud.add_child(inspector)
	building_inspector = BuildingInspector.new()
	building_inspector.name = "BuildingInspector"
	building_inspector.setup(session.buildings, session.crates, session.inventory, registry,
			session.materials, session.farming, session.kitchens)
	building_inspector.kitchen_target_changed.connect(set_kitchen_target)
	building_inspector.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	building_inspector.offset_left = -BuildingInspector.PANEL_WIDTH - 16
	building_inspector.offset_right = -16
	building_inspector.offset_top = INSPECTOR_TOP
	building_inspector.filter_changed.connect(func(_m: Array[StringName]) -> void: apply_crate_filter())
	building_inspector.deconstruct_requested.connect(deconstruct_selected_building)
	building_inspector.close_requested.connect(func() -> void: select_building(""))
	hud.add_child(building_inspector)
	toast = Label.new()
	toast.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	toast.offset_top = -120
	toast.offset_bottom = -72
	toast.offset_left = -300
	toast.offset_right = 300
	toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	toast.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
		building_view.set_visible_rect(view)
		room_overlay.set_visible_rect(view)
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
	day_tint.color = tint_for_tick(session.clock.tick_index)
	_update_hud()


## World tint for a simulation tick (pure; uses GameTime's day offset).
static func tint_for_tick(tick: int) -> Color:
	var in_day := posmod(tick + GameTime.START_OFFSET, GameTime.TICKS_PER_DAY)
	var h := float(in_day) / GameTime.TICKS_PER_HOUR
	for i in range(1, TINT_KEYS.size()):
		var b: Array = TINT_KEYS[i]
		var hb: float = b[0]
		if h <= hb:
			var a: Array = TINT_KEYS[i - 1]
			var ha: float = a[0]
			var t: float = (h - ha) / maxf(0.0001, hb - ha)
			return (a[1] as Color).lerp(b[1] as Color, clampf(t, 0.0, 1.0))
	return TINT_NIGHT


func set_tool(t: int) -> void:
	tools.set_tool(t)
	camera.left_drag_pans = t == ToolController.Tool.SELECT
	toolbar.set_active_tool(t)
	overlay.show_priorities = t == ToolController.Tool.PRIORITY
	if t != ToolController.Tool.SELECT:
		cancel_move()


# --- Build menu, placement, rooms ---------------------------------------

func open_build_menu() -> void:
	build_menu.visible = not build_menu.visible
	if build_menu.visible:
		set_overview_visible(false)
	toolbar.set_active_tool(tools.tool)  # the Build button only shows the menu


func close_build_menu() -> void:
	build_menu.visible = false


## Placement mode for a building key (build menu entry).
func start_placement(key: StringName) -> CommandResult:
	var r := tools.start_placement(key)
	if r.ok:
		cancel_move()
		camera.left_drag_pans = false
		toolbar.set_active_tool(ToolController.Tool.PLACE_BUILDING)
		overlay.show_priorities = false
		close_build_menu()
		show_toast("Place %s: click its bottom-left tile (Esc / right-click to stop)" % session.buildings.def(key).display_name)
	_on_command_result(r)
	return r


func set_rooms_visible(on: bool) -> void:
	room_overlay.visible = on
	toolbar.set_rooms_active(on)


# --- M4a: overview, alerts, schedules, beds, kitchens --------------------

## Colony overview (button / C). Shares the left column with the build menu
## and the screen centre with the schedule editor, so those close.
func set_overview_visible(on: bool) -> void:
	overview.visible = on
	toolbar.set_colony_active(on)
	if on:
		close_build_menu()
		set_schedule_visible(false)
		overview.refresh()


## Selects an NPC and centres the camera on it (overview rows, alerts).
func focus_npc(npc_id: String) -> CommandResult:
	var n := session.colony.get_npc(npc_id)
	if n == null:
		var r := CommandResult.failure(&"unknown_npc", "That colonist is gone")
		_on_command_result(r)
		return r
	select_building("")
	select_npc(npc_id)
	center_on_tile(n.tile + Vector2i(0, -1))
	return CommandResult.success({"npc_id": npc_id})


func center_on_tile(t: Vector2i) -> void:
	var px := scale_config.tile_size_px
	camera.position = CameraController.clamp_center(Vector2((t.x + 0.5) * px, (t.y + 0.5) * px),
			camera.view_size_world(), camera.world_size_px)


## Alert row clicked: its NPC (selected + centred) or else its tile.
func focus_alert(alert: Dictionary) -> CommandResult:
	var npc_id: String = alert.get("npc_id", "")
	if not npc_id.is_empty() and session.colony.get_npc(npc_id) != null:
		return focus_npc(npc_id)
	var t: Vector2i = alert.get("tile", AlertService.NO_TILE)
	if t != AlertService.NO_TILE:
		center_on_tile(t)
		return CommandResult.success({"tile": t})
	return CommandResult.failure(&"no_location", "This alert has no place to show")


func set_schedule_visible(on: bool) -> void:
	var n := selected_npc()
	on = on and n != null
	schedule_editor.visible = on
	inspector.set_schedule_open(on)
	if on:
		set_overview_visible(false)
		schedule_editor.show_schedule(n.nickname, n.schedule)


func set_selected_schedule(hours: PackedByteArray) -> CommandResult:
	var r := session.colony.set_schedule(selected_npc_id, hours)
	_on_command_result(r)
	return r


func set_schedule_all(hours: PackedByteArray) -> CommandResult:
	var r := session.colony.set_schedule_all(hours)
	if r.ok:
		show_toast("Schedule applied to all %d colonists" % session.colony.count())
	_on_command_result(r)
	return r


func assign_bed(bed_id: String) -> CommandResult:
	var r := session.colony.assign_bed(selected_npc_id, bed_id)
	_on_command_result(r)
	inspector.refresh()
	return r


func set_kitchen_target(kg: float) -> CommandResult:
	var r := session.kitchens.set_target_kg(selected_building_id, kg)
	_on_command_result(r)
	return r


# --- Building selection -------------------------------------------------

func select_building(building_id: String) -> void:
	selected_building_id = building_id if not session.buildings.get_building(building_id).is_empty() else ""
	building_view.selected_id = selected_building_id
	building_inspector.show_building(selected_building_id)


## Pushes the inspector's checkboxes to CrateStorage.set_filter. Unticking
## every material is refused ([] would mean "accept all").
func apply_crate_filter() -> CommandResult:
	var any := false
	for m in building_inspector.filter_checks:
		any = any or (building_inspector.filter_checks[m] as CheckBox).button_pressed
	var r: CommandResult
	if not any:
		r = CommandResult.failure(&"empty_filter", "A crate must accept at least one material")
	else:
		r = session.crates.set_filter(selected_building_id, building_inspector.checked_materials())
	_on_command_result(r)
	building_inspector.refresh()
	return r


func deconstruct_selected_building() -> CommandResult:
	var b := session.buildings.get_building(selected_building_id)
	var r: CommandResult
	if b.is_empty():
		r = CommandResult.failure(&"no_selection", "Select a building first")
	else:
		r = session.designations.designate(session.buildings.footprint(b["key"], b["origin"]),
				DesignationMap.Kind.DECONSTRUCT, tools.priority)
		if r.ok:
			show_toast("Deconstruct ordered")
	_on_command_result(r)
	return r


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
	select_building(session.buildings.building_at(tile) if n == null else "")
	return CommandResult.success({"selected": selected_npc_id, "building": selected_building_id})


func select_npc(npc_id: String) -> void:
	var n: Npc = session.colony.get_npc(npc_id) if not npc_id.is_empty() else null
	selected_npc_id = n.id if n != null else ""
	move_pending = false
	npc_layer.set_selected(selected_npc_id)
	inspector.show_npc(n)
	if schedule_editor.visible:
		set_schedule_visible(n != null)  # follow the new selection (or close)


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
	elif k.keycode == KEY_R and not k.ctrl_pressed:
		set_rooms_visible(not room_overlay.visible)
	elif k.keycode == KEY_C and not k.ctrl_pressed:
		set_overview_visible(not overview.visible)
	elif k.keycode == KEY_ESCAPE:
		if move_pending:
			cancel_move()
		elif build_menu.visible:
			close_build_menu()
		elif schedule_editor.visible:
			set_schedule_visible(false)
		elif overview.visible:
			set_overview_visible(false)
		elif tools.tool == ToolController.Tool.SELECT:
			select_npc("")
			select_building("")
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
		var bid := session.buildings.building_at(cursor)
		if not bid.is_empty():
			tile_name += " + " + session.buildings.def(session.buildings.get_building(bid)["key"]).display_name
	var room := RoomOverlay.describe(session.rooms.room_at(cursor))
	debug_hud.text = "%s | FPS %d | tick %d (%.2f ms)\nchunks %d | orders %d + %d bld | NPCs %d | jobs %d\nbuildings %d | rooms %d | hash %s\ncursor (%d, %d) %s%s%s" % [
		session.meta.get("name", ""), Engine.get_frames_per_second(), session.clock.tick_index, last_tick_ms,
		world_view.loaded_chunk_count(), session.designations.count(), session.build_orders.count(),
		session.colony.count(), session.jobs.job_count(),
		session.buildings.count(), session.rooms.room_count(), _hash_cache,
		cursor.x, cursor.y, tile_name, " · room: " + room if not room.is_empty() else "",
		"\nDEV INSTANT EDIT (F9)" if tools.dev_instant else ""]
