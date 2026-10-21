class_name NpcView
extends Node2D
## Body of one colonist. Node origin = bottom-centre of the feet tile (D-003
## pivot). Reads the Npc and Inventory every frame (Colony does not emit per
## tick); never mutates.
##
## Two looks (D-027): the role's production sprite sheet for animations that
## exist (walk, dig, ...), drawn by a Sprite2D whose frame follows the ground
## actually covered (feet do not slide) and whose per-frame head wobble is
## cancelled; idle uses a still walk frame with breathing / weight shift.
## Animations without a sheet use the procedural chibi rig (ProcFigure),
## posed continuously (smooth at any frame rate). Facing flips are animated.
## Per frame only transforms change — no redraws — so 100 NPCs stay cheap.

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
## Rig: one full walk cycle per this many tiles travelled.
const STRIDE_TILES := 1.0
## Seconds a work animation keeps playing after work_progress last changed
## (stops the swing while the game is paused).
const WORK_HOLD_SEC := 0.35
## Rig work swings per second.
const WORK_CYCLES_PER_SEC := 1.6
const IDLE_BLINK_PERIOD := 3.2
## Rig walk: one 4-key cycle (two steps) per this many tiles.
const RIG_STRIDE_TILES := 1.2
## Idle breathing / weight-shift periods (s) and amplitudes.
const BREATH_PERIOD := 2.6
const BREATH_AMOUNT := 0.014
const SWAY_PERIOD := 5.3
const SWAY_SKEW := 0.018
## Facing flip speed (scale units per second; 2 = one full flip).
const FLIP_RATE := 12.0
## Rate (1/s) at which the head-stabilising x offset follows its target.
const STABILISE_RATE := 20.0
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
var _sheet_root: Node2D    # production sheet: sprite + carried chunk
var _sprite: Sprite2D
var _sheet_carry: ProcFigure.Part
var _cur_sheet: Texture2D
var _overlay: Node2D       # selection + work bar, above the body
var _bar := -1
var _facing := 1.0
var _facing_vis := 1.0
var _dx := 0.0
var _anim: StringName = &"idle"
var _frame := 0
var _uses_sheet := false
var _rig_key := ""
var _walk_dist := 0.0
var _work_time := 0.0
var _work_hold := 0.0
var _last_work := 0.0
var _idle_time := 0.0
var _carry_color := Color(0, 0, 0, 0)
var _sheets: Dictionary = {}  # anim -> ArtLibrary.npc_anim_sheet() result
var _bake_vp: SubViewport
var _bake_tries := 0
var _baked := false
var _skel: RigFigure
## Roles drawn by the skeletal cut-out rig (D-027 pilot: miner only).
static var rig_roles: Array[StringName] = [&"miner"]


func setup(n: Npc, inv: Inventory, reg: TileRegistry, px: int) -> void:
	npc = n
	inventory = inv
	registry = reg
	tile_px = px
	_color = color_for_id(n.id)
	_look = ProcFigure.look_for_id(n.id, _color)
	# De-synchronise idle blinks / breathing between NPCs.
	_idle_time = fposmod(absi(n.id.hash()) * 0.137, IDLE_BLINK_PERIOD)


func _ready() -> void:
	_body = Node2D.new()
	_body.name = "Body"
	add_child(_body)
	_parts = ProcFigure.build(_body, _look)
	_sheet_root = Node2D.new()
	_sheet_root.name = "Sheet"
	add_child(_sheet_root)
	_sprite = Sprite2D.new()
	_sprite.centered = false
	_sprite.offset = Vector2(-ArtLibrary.NPC_CELL.x / 2.0, -ArtLibrary.NPC_CELL.y)
	_sheet_root.add_child(_sprite)
	_sheet_carry = ProcFigure.Part.new()
	_sheet_carry.painter = func(ci: ProcFigure.Part) -> void: ProcFigure.draw_chunk(ci, ArtLibrary.SHEET_CARRY_AT, 14.0, ci.tint, 7)
	_sheet_root.add_child(_sheet_carry)
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
	if role() in rig_roles:
		var d := RigDef.for_role(role())
		if d != null:
			_skel = RigFigure.new()
			_skel.name = "Skeleton"
			_skel.setup(d)
			add_child(_skel)
			move_child(_skel, _overlay.get_index())
			_body.visible = false
			_sheet_root.visible = false
	position = target_position()
	sync(0.0)
	_bake_rig()


## Renders the rig's parts once into a small atlas (one-shot SubViewport) and
## switches the parts to textured rects: GL Compatibility draws each vector
## polygon as its own draw call, textured rects batch. Skipped headless
## (tests), where the vector parts are kept.
func _bake_rig() -> void:
	if DisplayServer.get_name() == "headless" or _skel != null:
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
	_facing_vis = move_toward(_facing_vis, _facing, delta * FLIP_RATE)
	_idle_time += delta
	if npc.work_progress != _last_work:
		_last_work = npc.work_progress
		_work_hold = WORK_HOLD_SEC
	if _work_hold > 0.0:
		_work_hold -= delta
		_work_time += delta
	sync(delta)


## Pulls the NPC fields that affect drawing and updates transforms / frames.
func sync(delta: float = 0.0) -> void:
	if label.text != npc.nickname:
		label.text = npc.nickname
	var carried := inventory.carried_by(npc.id)
	var material: StringName = carried.material if carried else &""
	var vertical := npc.prev_tile.x == npc.tile.x and npc.prev_tile.y != npc.tile.y
	_anim = anim_for(npc.state, npc.is_moving(), vertical, carried != null)
	_carry_color = material_art_color(registry, material) if carried else ProcFigure.NO_CARRY
	if _skel:
		_sync_skeleton()
	else:
		_sync_look(delta)
	var bar := roundi(npc.work_progress * 50.0) if (npc.state == &"working" or npc.work_progress > 0.0) else -1
	if bar != _bar:
		_bar = bar
		_overlay.queue_redraw()


## Skeletal cut-out rig pilot (D-027 step 3): one smooth rig for every anim.
func _sync_skeleton() -> void:
	var k := tile_px / 64.0
	_skel.scale = Vector2(k * _facing_vis, k)
	var phase := 0.0
	match _anim:
		&"walk", &"carry", &"climb":
			phase = _walk_dist / (tile_px * RIG_STRIDE_TILES)
		&"dig", &"build":
			phase = _work_time / float(RigAnim.LOOP_SEC.get(_anim, 0.8))
		_:
			phase = _idle_time / float(RigAnim.LOOP_SEC.get(_anim, 3.0))
	var blink := fposmod(_idle_time, IDLE_BLINK_PERIOD) > IDLE_BLINK_PERIOD - 0.15
	_frame = floori(fposmod(phase, 1.0) * 4.0)
	_skel.apply(_anim, phase, blink, _carry_color)


## True when this NPC is drawn by the skeletal rig.
func uses_skeleton() -> bool:
	return _skel != null


func _sync_look(delta: float) -> void:
	var info := _sheet_info(_anim)
	_uses_sheet = info.has("sheet")
	_body.visible = not _uses_sheet
	_sheet_root.visible = _uses_sheet
	if _uses_sheet:
		_sync_sheet(info, delta)
	else:
		_sync_rig()


func _sync_sheet(info: Dictionary, delta: float) -> void:
	var sheet: Texture2D = info.sheet
	var count := ArtLibrary.frame_count(sheet, info.anim)
	if sheet != _cur_sheet:
		_cur_sheet = sheet
		_sprite.texture = sheet
		_sprite.hframes = count
		var cell := ArtLibrary.cell_size(info.anim)
		_sprite.offset = Vector2(-cell.x / 2.0, -cell.y)
	var metrics := ArtLibrary.sheet_metrics(role(), info.anim)
	var k := tile_px / 64.0
	if info.hold:
		_frame = info.frame
	else:
		match _anim:
			&"walk", &"carry", &"climb":
				# One loop of the sheet per cycle_px of ground: feet stay planted.
				_frame = floori(_walk_dist / (float(metrics.cycle_px) * k / count)) % count
			&"idle", &"sleep", &"fall":
				_frame = idle_frame(_idle_time, count)
			_:
				_frame = floori(_work_time * ArtLibrary.ANIM_FPS.get(info.anim, 8.0)) % count
	_sprite.frame = _frame
	var dxs: PackedFloat32Array = metrics.dx
	var target: float = dxs[_frame] if _frame < dxs.size() else 0.0
	_dx = target if delta <= 0.0 else lerpf(_dx, target, 1.0 - exp(-STABILISE_RATE * delta))
	_sprite.position.x = _dx
	var sx := 1.0
	var sy := 1.0
	var skew := 0.0
	if _anim == &"idle":
		# Idle: breathing (stretch from the feet up) and a slow weight shift.
		var b := sin(TAU * _idle_time / BREATH_PERIOD)
		sy = 1.0 + BREATH_AMOUNT * b
		sx = 1.0 - BREATH_AMOUNT * 0.5 * b
		skew = SWAY_SKEW * sin(TAU * _idle_time / SWAY_PERIOD)
	_sheet_root.scale = Vector2(k * _facing_vis * sx, k * sy)
	_sheet_root.skew = skew
	var holding := _anim == &"carry" and _carry_color.a > 0.0
	_sheet_carry.visible = holding
	if holding:
		_sheet_carry.tint = _carry_color


func _sync_rig() -> void:
	var phase := 0.0
	match _anim:
		&"walk", &"carry", &"climb":
			phase = _walk_dist / (tile_px * STRIDE_TILES)
		&"dig", &"build":
			phase = _work_time * WORK_CYCLES_PER_SEC
		_:
			phase = _idle_time / BREATH_PERIOD
	var blink := fposmod(_idle_time, IDLE_BLINK_PERIOD) > IDLE_BLINK_PERIOD - 0.15
	_frame = floori(fposmod(phase, 1.0) * ProcFigure.FRAMES.get(_anim, 1))
	var k := tile_px / 64.0
	_body.scale = Vector2(k * _facing_vis, k)
	# Re-pose only when the pose visibly changes (~120 steps per loop).
	var key := "%s|%d|%s|%s" % [_anim, roundi(fposmod(phase, 1.0) * 120.0), _carry_color.to_html(), blink]
	if key != _rig_key:
		_rig_key = key
		ProcFigure.apply_pose_at(_parts, _anim, phase, _carry_color, blink)


func target_position() -> Vector2:
	return feet_position(npc.prev_tile, npc.tile, npc.move_progress, tile_px)


## Cosmetic role used for outfits / sheet names (not a gameplay role).
func role() -> StringName:
	return _look.get(&"role", &"miner")


func current_anim() -> StringName:
	return _anim


func current_frame() -> int:
	return _frame


## True when the current animation is drawn from a production sheet.
func uses_sheets() -> bool:
	return _uses_sheet


## Visual facing (-1..1, animated through 0 when turning).
func facing_visual() -> float:
	return _facing_vis


func _sheet_info(anim: StringName) -> Dictionary:
	if not _sheets.has(anim):
		_sheets[anim] = ArtLibrary.npc_anim_sheet(role(), anim)
	return _sheets[anim]


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

## Frame of a slow "still" sheet (idle / sleep / fall) at time t: the owner's
## 4-frame idle sheets have the blink in frame 1, which is shown only briefly
## once per loop; other frames are held about a second each (2-frame sheets
## alternate slowly).
static func idle_frame(t: float, count: int) -> int:
	if count == 4:
		var durations := [1.1, 0.14, 1.0, 1.0]
		var total := 3.24
		var u := fposmod(t, total)
		for i in 4:
			if u < durations[i]:
				return i
			u -= durations[i]
		return 3
	return floori(t / 1.2) % maxi(count, 1)


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
