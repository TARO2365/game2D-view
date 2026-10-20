class_name NpcView
extends Node2D
## Body of one colonist. Node origin = bottom-centre of the feet tile (D-003
## pivot). Reads the Npc and Inventory every frame (Colony does not emit per
## tick); never mutates. Draws a production sprite sheet when one exists
## (ArtLibrary, ASSET_SPEC §6), otherwise the procedural chibi rig
## (ProcFigure, D-020) whose parts are recorded once and only moved per
## animation frame — cheap enough for 100 NPCs.

const BODY_HEIGHT_TILES := 2.5    # D-003: ~2.5-tile sprite
const BAR_WIDTH_TILES := 0.8      # PLACEHOLDER
const BAR_HEIGHT_PX := 6.0
## Gap between the top of the 2.5-tile body box and the work bar (px).
const BAR_GAP_PX := 26.0
const LABEL_WIDTH_PX := 240.0
const LABEL_FONT_SIZE := 18       # PLACEHOLDER
## Visual smoothing toward the interpolated tick position (1/s). PLACEHOLDER.
const SMOOTH_RATE := 18.0
## Farther than this (tiles) the view snaps instead of sliding (load, teleport).
const SNAP_TILES := 3.0
## One full walk cycle per this many tiles travelled.
const STRIDE_TILES := 1.0
## Seconds a work animation keeps playing after work_progress last changed
## (stops the swing while the game is paused).
const WORK_HOLD_SEC := 0.35
const IDLE_BLINK_PERIOD := 3.2
## Frames to wait for the rig bake before keeping the vector parts.
const BAKE_MAX_FRAMES := 4
## Atlas pixel that must be opaque once the bake rendered (torso centre).
const BAKE_PROBE := Vector2i(195, 27)
const OUTLINE_COLOR := Color(0.05, 0.04, 0.04)
const SELECT_COLOR := Color(1.0, 0.92, 0.25)
const BAR_BG := Color(0, 0, 0, 0.7)
const BAR_FG := Color(0.35, 0.95, 0.4)

var npc: Npc
var inventory: Inventory
var registry: TileRegistry
var tile_px := 64
var selected := false:
	set(v):
		if v != selected:
			selected = v
			if _overlay:
				_overlay.queue_redraw()
var label: Label

var _color := Color.WHITE
var _look: Dictionary = {}
var _body: Node2D          # procedural rig root (scaled for tile size / facing)
var _parts: Dictionary = {}
var _overlay: Node2D       # selection + work bar, above the body
var _pose_key := ""
var _sheet_key := ""
var _bar := -1
var _facing := 1.0
var _anim: StringName = &"idle"
var _frame := 0
var _walk_dist := 0.0
var _work_time := 0.0
var _work_hold := 0.0
var _last_work := 0.0
var _idle_time := 0.0
var _carry_color := Color(0, 0, 0, 0)
var _sheets: Dictionary = {}  # anim -> Texture2D or null
var _bake_vp: SubViewport
var _bake_tries := 0
var _baked := false


func setup(n: Npc, inv: Inventory, reg: TileRegistry, px: int) -> void:
	npc = n
	inventory = inv
	registry = reg
	tile_px = px
	_color = color_for_id(n.id)
	_look = ProcFigure.look_for_id(n.id, _color)
	# De-synchronise idle blinks between NPCs.
	_idle_time = fposmod(absi(n.id.hash()) * 0.137, IDLE_BLINK_PERIOD)


func _ready() -> void:
	_body = Node2D.new()
	_body.name = "Body"
	add_child(_body)
	_parts = ProcFigure.build(_body, _look)
	var ov := ProcFigure.Part.new()
	ov.name = "Overlay"
	ov.painter = _draw_overlay
	add_child(ov)
	_overlay = ov
	label = Label.new()
	label.name = "Nickname"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", LABEL_FONT_SIZE)
	label.add_theme_constant_override("outline_size", 5)
	label.add_theme_color_override("font_outline_color", OUTLINE_COLOR)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.size = Vector2(LABEL_WIDTH_PX, LABEL_FONT_SIZE + 10)
	label.position = Vector2(-LABEL_WIDTH_PX / 2.0, -BODY_HEIGHT_TILES * tile_px - BAR_GAP_PX - LABEL_FONT_SIZE - 14)
	add_child(label)
	position = target_position()
	sync()
	_bake_rig()


## Renders the rig's parts once into a small atlas (one-shot SubViewport) and
## switches the parts to textured rects: GL Compatibility draws each vector
## polygon as its own draw call, textured rects batch. Skipped headless
## (tests), where the vector parts are kept.
func _bake_rig() -> void:
	if DisplayServer.get_name() == "headless":
		return
	_bake_vp = SubViewport.new()
	_bake_vp.name = "RigBake"
	_bake_vp.size = ProcFigure.ATLAS_SIZE
	_bake_vp.transparent_bg = true
	_bake_vp.disable_3d = true
	_bake_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	ProcFigure.populate_bake(_bake_vp, _look)
	add_child(_bake_vp)
	_bake_tries = BAKE_MAX_FRAMES
	# A bound-method connection is dropped automatically if this view is freed.
	RenderingServer.frame_post_draw.connect(_on_bake_frame)


func _on_bake_frame() -> void:
	_bake_tries -= 1
	var img := _bake_vp.get_texture().get_image()
	var ok := img != null and not img.is_empty() and img.get_pixelv(BAKE_PROBE).a > 0.5
	if ok:
		ProcFigure.use_atlas(_parts, ImageTexture.create_from_image(img))
		_baked = true
	if ok or _bake_tries <= 0:
		RenderingServer.frame_post_draw.disconnect(_on_bake_frame)
		_bake_vp.queue_free()
		_bake_vp = null


## True once the rig draws from its baked atlas (tests / HUD).
func is_baked() -> bool:
	return _baked


func _process(delta: float) -> void:
	var before := position
	position = smooth_toward(position, target_position(), delta, SMOOTH_RATE, SNAP_TILES * tile_px)
	var moved := position - before
	if moved.length() < SNAP_TILES * tile_px:
		_walk_dist += moved.length()
	if absf(moved.x) > 0.05:
		_facing = signf(moved.x)
	_idle_time += delta
	if npc.work_progress != _last_work:
		_last_work = npc.work_progress
		_work_hold = WORK_HOLD_SEC
	if _work_hold > 0.0:
		_work_hold -= delta
		_work_time += delta
	sync()


## Pulls the NPC fields that affect drawing; touches nodes only on change.
func sync() -> void:
	if label.text != npc.nickname:
		label.text = npc.nickname
	var carried := inventory.carried_by(npc.id)
	var material: StringName = carried.material if carried else &""
	var vertical := npc.prev_tile.x == npc.tile.x and npc.prev_tile.y != npc.tile.y
	_anim = anim_for(npc.state, npc.is_moving(), vertical, carried != null)
	_frame = _frame_for(_anim)
	var key := "%s|%d|%d|%s" % [_anim, _frame, int(_facing), material]
	if key != _pose_key:
		_pose_key = key
		_carry_color = material_art_color(registry, material) if carried else ProcFigure.NO_CARRY
		var k := tile_px / 64.0
		var sheet := _sheet(_anim)
		_body.visible = sheet == null
		if sheet == null:
			_body.scale = Vector2(k * _facing, k)
			ProcFigure.apply_pose(_parts, _anim, _frame, _carry_color)
		if sheet != null or _sheet_key != "":
			_sheet_key = key if sheet else ""
			queue_redraw()
	var bar := roundi(npc.work_progress * 50.0) if (npc.state == &"working" or npc.work_progress > 0.0) else -1
	if bar != _bar:
		_bar = bar
		_overlay.queue_redraw()


func target_position() -> Vector2:
	return feet_position(npc.prev_tile, npc.tile, npc.move_progress, tile_px)


## Cosmetic role used for outfits / sheet names (not a gameplay role).
func role() -> StringName:
	return _look.get(&"role", &"miner")


func current_anim() -> StringName:
	return _anim


func current_frame() -> int:
	return _frame


## Production sheet for an animation of this NPC's role, or null (cached).
func _sheet(anim: StringName) -> Texture2D:
	if not _sheets.has(anim):
		_sheets[anim] = ArtLibrary.npc_sheet(role(), anim)
	return _sheets[anim]


func _frame_for(anim: StringName) -> int:
	var sheet := _sheet(anim)
	var count: int = ArtLibrary.frame_count(sheet) if sheet else ProcFigure.FRAMES.get(anim, 1)
	match anim:
		&"walk", &"carry", &"climb":
			return floori(_walk_dist / (tile_px * STRIDE_TILES / count)) % count
		&"dig", &"build":
			return floori(_work_time * ArtLibrary.ANIM_FPS.get(anim, 8.0)) % count
	if sheet:
		return floori(_idle_time * ArtLibrary.ANIM_FPS.get(anim, 4.0)) % count
	# Procedural idle: gentle breathing bob, blink once per period.
	if fposmod(_idle_time, IDLE_BLINK_PERIOD) > IDLE_BLINK_PERIOD - 0.15:
		return 2
	return 1 if fposmod(_idle_time, 1.6) > 0.8 else 0


## Production sheet frame (only when a sheet exists for the current anim).
func _draw() -> void:
	var sheet := _sheet(_anim)
	if sheet == null:
		return
	var k := tile_px / 64.0
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(k * _facing, k))
	var cell := Vector2(ArtLibrary.NPC_CELL)
	draw_texture_rect_region(sheet, Rect2(Vector2(-cell.x / 2.0, -cell.y), cell),
			ArtLibrary.frame_region(_frame, ArtLibrary.frame_count(sheet)))
	if _carry_color.a > 0.0:
		ProcFigure.draw_chunk(self, ProcFigure.CARRY_AT, 13.0, _carry_color, 7)
	draw_set_transform(Vector2.ZERO)


func _draw_overlay(ci: Node2D) -> void:
	var px := float(tile_px)
	if selected:
		ci.draw_set_transform(Vector2(0, -2), 0.0, Vector2(1.0, 0.3))
		ci.draw_arc(Vector2.ZERO, 0.55 * px, 0.0, TAU, 32, SELECT_COLOR, 4.0)
		ci.draw_set_transform(Vector2.ZERO)
		ci.draw_rect(Rect2(-0.5 * px, -BODY_HEIGHT_TILES * px - 10.0, px, BODY_HEIGHT_TILES * px + 14.0), SELECT_COLOR, false, 3.0)
	# Work progress bar above the head.
	if _bar >= 0:
		var bw := BAR_WIDTH_TILES * px
		var bar := Rect2(-bw / 2.0, -BODY_HEIGHT_TILES * px - BAR_GAP_PX, bw, BAR_HEIGHT_PX)
		ci.draw_rect(bar.grow(1.5), OUTLINE_COLOR)
		ci.draw_rect(bar, BAR_BG)
		ci.draw_rect(Rect2(bar.position, Vector2(bw * clampf(npc.work_progress, 0.0, 1.0), BAR_HEIGHT_PX)), BAR_FG)


# --- Pure helpers (unit tested) -------------------------------------------

## Animation for the NPC's visible state (ASSET_SPEC §6 animation list).
static func anim_for(state: StringName, moving: bool, vertical: bool, carrying: bool) -> StringName:
	if state == &"working":
		return &"dig"
	if moving and vertical:
		return &"climb"
	if carrying:
		return &"carry"
	if moving:
		return &"walk"
	return &"idle"


## Bottom-centre of the feet tile, interpolated along the current step.
static func feet_position(prev: Vector2i, tile: Vector2i, progress: float, px: int) -> Vector2:
	var t := clampf(progress, 0.0, 1.0)
	var p := Vector2(prev).lerp(Vector2(tile), t)
	return Vector2((p.x + 0.5) * px, (p.y + 1.0) * px)


## Frame-rate independent exponential approach; snaps on large jumps.
static func smooth_toward(current: Vector2, target: Vector2, delta: float, rate: float, snap_dist: float) -> Vector2:
	if current.distance_to(target) > snap_dist:
		return target
	return current.lerp(target, 1.0 - exp(-rate * delta))


## Distinct, stable colour per NPC id ("npc:3"): golden-ratio hue steps.
static func color_for_id(id: String) -> Color:
	var n := id.get_slice(":", 1).to_int() if id.contains(":") else id.hash()
	return Color.from_hsv(fposmod(n * 0.618034, 1.0), 0.6, 0.85)


## TileDef.placeholder_color of a material key (magenta if unknown).
static func material_color(reg: TileRegistry, material: StringName) -> Color:
	for d in reg.all_defs():
		if d.key == material:
			return d.placeholder_color
	return Color.MAGENTA


## Art colour of a material chunk (palette), falling back to material_color.
static func material_art_color(reg: TileRegistry, material: StringName) -> Color:
	match material:
		&"dirt":
			return ArtPalette.DIRT_LIGHT
		&"rock":
			return ArtPalette.ROCK_LIGHT
		&"iron_ore":
			return ArtPalette.IRON
		&"gold_ore":
			return ArtPalette.GOLD
		&"crystal":
			return ArtPalette.CRYSTAL
	return material_color(reg, material)
