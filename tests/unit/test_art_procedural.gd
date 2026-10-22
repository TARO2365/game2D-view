extends GutTest
## Procedural path-B art (D-020): deterministic, cached, variants differ,
## tileset layout keeps Vector2i(id, 0), NPC animation selection.

var reg: TileRegistry


func before_all() -> void:
	reg = TileRegistry.load_default()
	ArtLibrary.clear_cache()


func test_every_solid_material_has_procedural_tiles() -> void:
	for d in reg.all_defs():
		if not d.solid:
			continue
		for v in ProcTerrain.VARIANTS:
			var img := ProcTerrain.tile(d.key, v, 64)
			assert_not_null(img, "%s variant %d" % [d.key, v])
			assert_eq(img.get_size(), Vector2i(64, 64))
			assert_eq(img.get_pixel(32, 32).a, 1.0, "%s is opaque" % d.key)


func test_tiles_are_deterministic_and_cached() -> void:
	var a := ProcTerrain.tile(&"gold_ore", 2, 64)
	assert_same(a, ProcTerrain.tile(&"gold_ore", 2, 64), "cached instance")
	var cv1 := PixelCanvas.new(8, 8)
	var cv2 := PixelCanvas.new(8, 8)
	cv1.ellipse(4, 4, 3, 2, Color.RED)
	cv2.ellipse(4, 4, 3, 2, Color.RED)
	assert_eq(cv1.data, cv2.data)
	assert_eq(PixelCanvas.hash01(3, 4, 5), PixelCanvas.hash01(3, 4, 5))


func test_variants_differ() -> void:
	for key in [&"dirt", &"rock", &"iron_ore", &"crystal"]:
		var a := ProcTerrain.tile(key, 0, 64).get_data()
		var b := ProcTerrain.tile(key, 1, 64).get_data()
		assert_ne(a, b, "%s variants differ" % key)


func test_unknown_material_has_no_procedural_tile() -> void:
	assert_null(ProcTerrain.tile(&"unobtainium", 0, 64))


func test_rim_is_darker_than_centre() -> void:
	var img := ProcTerrain.tile(&"dirt", 0, 64)
	var rim := 0.0
	var inner := 0.0
	for y in range(8, 56):
		rim += img.get_pixel(0, y).get_luminance()
		inner += img.get_pixel(20, y).get_luminance()
	assert_lt(rim, inner, "edge column is darker on average")


func test_ladder_tile_transparent_between_rails() -> void:
	var img := ProcTerrain.ladder(64)
	assert_eq(img.get_size(), Vector2i(64, 64))
	assert_eq(img.get_pixel(32, 1).a, 0.0, "gap between rungs is see-through")
	var opaque := 0
	for x in 64:
		if img.get_pixel(x, 32).a > 0.5:
			opaque += 1
	assert_gt(opaque, 30, "a rung crosses the middle")


func test_tileset_layout_keeps_row_zero_tiles() -> void:
	var ts := PlaceholderTiles.build_tileset(reg, 32)
	var src := ts.get_source(PlaceholderTiles.TERRAIN_SOURCE) as TileSetAtlasSource
	assert_eq(src.texture.get_height(), 32 * PlaceholderTiles.VARIANTS, "variant rows")
	for d in reg.all_defs():
		assert_eq(src.has_tile(Vector2i(d.id, 0)), d.solid, "%s" % d.key)
		if d.solid:
			assert_not_null(src.get_tile_data(Vector2i(d.id, 0), 0).material, "variant shader")
	assert_false(src.has_tile(Vector2i(TileRegistry.DIRT, 1)), "variant rows are not tiles")
	var st := ts.get_source(PlaceholderTiles.STRUCTURE_SOURCE) as TileSetAtlasSource
	assert_true(st.has_tile(Vector2i(WorldGrid.Structure.LADDER, 0)))


func test_anim_for_states() -> void:
	assert_eq(NpcView.anim_for(&"idle", false, false, false), &"idle")
	assert_eq(NpcView.anim_for(&"moving", true, false, false), &"walk")
	assert_eq(NpcView.anim_for(&"moving", true, true, false), &"climb")
	assert_eq(NpcView.anim_for(&"carrying", true, false, true), &"carry")
	assert_eq(NpcView.anim_for(&"carrying", false, false, true), &"carry")
	assert_eq(NpcView.anim_for(&"working", false, false, false), &"dig")
	# M4a needs.
	assert_eq(NpcView.anim_for(&"sleeping", false, false, false), &"sleep")
	assert_eq(NpcView.anim_for(&"sleeping", true, false, false), &"walk", "walking to bed")
	assert_eq(NpcView.anim_for(&"collapsed", false, false, false), &"sleep", "lies down")
	assert_eq(NpcView.anim_for(&"eating", false, false, true), &"eat")
	assert_eq(NpcView.anim_for(&"eating", true, false, true), &"carry", "carrying food to a table")


func test_poses_cover_every_frame() -> void:
	for anim in ProcFigure.FRAMES:
		var seen: Array = []
		for f in ProcFigure.FRAMES[anim]:
			var p := ProcFigure.pose(anim, f)
			assert_true(p.has(&"arm_f") and p.has(&"leg_f") and p.has(&"bob"))
			seen.append(p)
		if ProcFigure.FRAMES[anim] > 1:
			assert_ne(seen[0], seen[1], "%s animates" % anim)


func test_rig_poses_move_parts_without_redraw_logic() -> void:
	var root := Node2D.new()
	add_child_autofree(root)
	var parts := ProcFigure.build(root, ProcFigure.look_for_id("npc:1", Color.RED))
	assert_eq(root.get_child_count(), 8, "shadow, 2 arms, 2 legs, torso, head, carry")
	ProcFigure.apply_pose(parts, &"walk", 0, ProcFigure.NO_CARRY)
	var r0: float = (parts[&"leg_f"] as Node2D).rotation
	ProcFigure.apply_pose(parts, &"walk", 2, ProcFigure.NO_CARRY)
	assert_ne((parts[&"leg_f"] as Node2D).rotation, r0, "legs swing")
	assert_false((parts[&"carry"] as Node2D).visible)
	ProcFigure.apply_pose(parts, &"carry", 1, Color.GOLD)
	assert_true((parts[&"carry"] as Node2D).visible, "held item shown")
	ProcFigure.apply_pose(parts, &"dig", 0, ProcFigure.NO_CARRY)
	assert_true((parts[&"pickaxe"] as Node2D).visible, "pickaxe while digging")


func test_pose_at_is_continuous() -> void:
	# Keys at phase 0 and 0.25 of the 4-key walk; halfway is in between.
	var a: float = ProcFigure.pose_at(&"walk", 0.0)[&"leg_f"]
	var b: float = ProcFigure.pose_at(&"walk", 0.25)[&"leg_f"]
	var mid: float = ProcFigure.pose_at(&"walk", 0.125)[&"leg_f"]
	assert_almost_eq(a, float(ProcFigure.pose(&"walk", 0)[&"leg_f"]), 0.001)
	assert_almost_eq(b, float(ProcFigure.pose(&"walk", 1)[&"leg_f"]), 0.001)
	assert_between(mid, minf(a, b), maxf(a, b))
	# Small phase steps give small pose changes (no snapping).
	var prev: float = ProcFigure.pose_at(&"dig", 0.0)[&"arm_f"]
	for i in range(1, 101):
		var cur: float = ProcFigure.pose_at(&"dig", i / 100.0)[&"arm_f"]
		assert_lt(absf(cur - prev), 0.15, "smooth at step %d" % i)
		prev = cur


func test_atlas_slots_fit_and_do_not_overlap() -> void:
	var atlas := Rect2(Vector2.ZERO, Vector2(ProcFigure.ATLAS_SIZE))
	var rects: Array[Rect2] = []
	for k in ProcFigure.SLOTS:
		var r := Rect2(ProcFigure.SLOTS[k][1], (ProcFigure.SLOTS[k][0] as Rect2).size)
		assert_true(atlas.encloses(r), "%s inside atlas" % k)
		for o in rects:
			assert_false(o.intersects(r), "%s overlaps another slot" % k)
		rects.append(r)


func test_use_atlas_swaps_painters() -> void:
	var root := Node2D.new()
	add_child_autofree(root)
	var parts := ProcFigure.build(root, ProcFigure.look_for_id("npc:2", Color.BLUE))
	var before: Callable = (parts[&"torso"] as ProcFigure.Part).painter
	var tex := ImageTexture.create_from_image(Image.create(ProcFigure.ATLAS_SIZE.x, ProcFigure.ATLAS_SIZE.y, false, Image.FORMAT_RGBA8))
	ProcFigure.use_atlas(parts, tex)
	var carry_before: Callable = (parts[&"carry"] as ProcFigure.Part).painter
	ProcFigure.use_atlas(parts, tex)
	assert_ne((parts[&"torso"] as ProcFigure.Part).painter, before)
	assert_eq((parts[&"carry"] as ProcFigure.Part).painter, carry_before, "carry stays vector (tinted per material)")


func test_looks_stable_and_roles_spread() -> void:
	var roles: Dictionary = {}
	for i in range(1, 9):
		var id := "npc:%d" % i
		var a := ProcFigure.look_for_id(id, NpcView.color_for_id(id))
		assert_eq(a, ProcFigure.look_for_id(id, NpcView.color_for_id(id)), "stable")
		roles[a[&"role"]] = true
	assert_eq(roles.size(), ProcFigure.ROLES.size(), "all four outfits appear")


func test_material_art_color_falls_back() -> void:
	assert_eq(NpcView.material_art_color(reg, &"gold_ore"), ArtPalette.GOLD)
	assert_eq(NpcView.material_art_color(reg, &"bedrock"), reg.get_def(TileRegistry.BEDROCK).placeholder_color)
	assert_eq(NpcView.material_art_color(reg, &"no_such"), ItemArt.UNKNOWN, "never magenta")


func test_every_material_def_has_colour_and_art() -> void:
	var mats := MaterialDefs.load_default()
	assert_gt(mats.all_keys().size(), 0)
	for k in mats.all_keys():
		var c := NpcView.material_art_color(reg, k)
		assert_ne(c, Color.MAGENTA, "%s colour" % k)
	for food in [&"mushroom", &"meal", &"ration"]:
		assert_eq(NpcView.material_art_color(reg, food), mats.get_def(food).color, "%s from MaterialDefs" % food)
		assert_eq(ArtLibrary.item_path(food), "items/item_%s.png" % food)
