extends GutTest
## Skeletal cut-out rig pilot (D-027 step 3).


func before_each() -> void:
	ArtLibrary.base_dir = "res://assets/production/"
	ArtLibrary.clear_cache()
	RigDef.clear_cache()


func test_anim_sampling_is_smooth_and_covers_all() -> void:
	for anim in [&"idle", &"walk", &"carry", &"climb", &"dig", &"build", &"sleep", &"fall"]:
		assert_true(RigAnim.has_anim(anim), String(anim))
		var prev := RigAnim.sample(anim, 0.0)
		for i in range(1, 201):
			var cur := RigAnim.sample(anim, i / 200.0)
			for ch in cur:
				assert_lt(absf(float(cur[ch]) - float(prev[ch])), 12.0, "%s/%s step %d" % [anim, ch, i])
			prev = cur
	assert_almost_eq(float(RigAnim.sample(&"walk", 0.0)[&"thigh_f"]), float(RigAnim.sample(&"walk", 1.0)[&"thigh_f"]), 0.001, "loops")


func test_pilot_rig_from_miner_sheet() -> void:
	if not FileAccess.file_exists("res://assets/production/characters/npc_miner_idle.png"):
		pass_test("no miner idle sheet")
		return
	var d := RigDef.for_role(&"miner")
	assert_not_null(d)
	assert_eq(d.source, "pilot")
	for p in [&"head", &"torso", &"upper_arm_b", &"upper_arm_f", &"thigh_b", &"thigh_f"]:
		assert_true(d.has_part(p), String(p))
	assert_gt(d.head_blink.size.x, 0.0, "blink head cut from the blink frame")
	# Head sits above the torso joint, thighs at the hip, feet near the ground.
	assert_lt(d.joint(&"head").y, d.joint(&"torso").y)
	assert_almost_eq(d.joint(&"pelvis").y, d.joint(&"thigh_f").y, 0.01)


func test_rig_figure_poses() -> void:
	if not FileAccess.file_exists("res://assets/production/characters/npc_miner_idle.png"):
		pass_test("no miner idle sheet")
		return
	var f := RigFigure.new()
	f.setup(RigDef.for_role(&"miner"))
	add_child_autofree(f)
	f.apply(&"walk", 0.0, false, ProcFigure.NO_CARRY)
	var leg: Node2D = f.get_node("thigh_f")
	var r0 := leg.rotation
	f.apply(&"walk", 0.5, false, ProcFigure.NO_CARRY)
	assert_ne(leg.rotation, r0, "legs swing")
	f.apply(&"dig", 0.3, false, ProcFigure.NO_CARRY)
	assert_true((f.get_node("prop") as Node2D).visible, "pickaxe while digging")
	f.apply(&"carry", 0.3, false, Color.GOLD)
	assert_true((f.get_node("carry") as Node2D).visible)
	var head: Sprite2D = f.get_node("head")
	var open := head.region_rect
	f.apply(&"idle", 0.0, true, ProcFigure.NO_CARRY)
	assert_ne(head.region_rect, open, "blink swaps the head region")
	# Draw order is plain child order (no z_index tricks).
	for c in f.get_children():
		assert_eq((c as CanvasItem).z_index, 0)


func test_parts_sheet_slicing() -> void:
	# Synthetic parts sheet: 4 rows of opaque boxes in the LAYOUT counts.
	var sheet := Image.create(1400, 1200, false, Image.FORMAT_RGBA8)
	var sizes := [
		[Vector2i(200, 220), Vector2i(220, 120), Vector2i(150, 170), Vector2i(140, 60)],
		[Vector2i(50, 90), Vector2i(45, 80), Vector2i(50, 50), Vector2i(50, 90), Vector2i(45, 80), Vector2i(50, 50)],
		[Vector2i(60, 90), Vector2i(55, 80), Vector2i(80, 55), Vector2i(60, 90), Vector2i(55, 80), Vector2i(80, 55)],
		[Vector2i(160, 220), Vector2i(200, 220)],
	]
	var y := 20
	for row in sizes:
		var x := 20
		var row_h := 0
		for s: Vector2i in row:
			sheet.fill_rect(Rect2i(Vector2i(x, y), s), Color(0.6, 0.4, 0.2))
			x += s.x + 60
			row_h = maxi(row_h, s.y)
		y += row_h + 60
	var res := RigPartsImport.slice(sheet)
	assert_false(res.has("error"), str(res.get("error", "")))
	var json: Dictionary = res.json
	assert_eq((json.parts as Dictionary).size(), 17, "16 body parts + prop (blink head kept separately)")
	var head: Array = json.parts["head"]["joint"]
	var boot: Array = json.parts["boot_f"]["joint"]
	assert_lt(float(head[1]), float(boot[1]), "head above boots")
	assert_eq((json.head_blink as Array).size(), 4)
	# Wrong part count is reported, not guessed.
	var bad := Image.create(400, 400, false, Image.FORMAT_RGBA8)
	bad.fill_rect(Rect2i(10, 10, 100, 100), Color.RED)
	assert_true(RigPartsImport.slice(bad).has("error"))
