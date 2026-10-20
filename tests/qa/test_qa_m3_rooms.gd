extends GutTest
## QA M3 criterion 3: rooms appear, change and disappear on EVERY kind of
## edit made through real NPC jobs (door, building placed, wall, deconstruct
## wall / door, dig) and through building loss and the size limit. After
## every tick the incrementally maintained rooms must equal a full rebuild
## (tools/qa_harness.gd rooms_vs_rebuild), plus all invariants.
##
## Layout (48x32, surface row 10): laddered shaft x=17 rows 10..17, corridor
## x=18..19 rows 15..17, pocket x=20..27 rows 15..17 (24 tiles).

const ENV := preload("res://tools/qa_m3_env.gd")
const QA := preload("res://tools/qa_harness.gd")
const K := DesignationMap.Kind

var reg: TileRegistry
var e: Variant
var s: WorldSession


func before_all() -> void:
	reg = TileRegistry.load_default()


func before_each() -> void:
	e = ENV.new(reg)
	s = e.ses


func _step(ticks: int, cond: Callable, msg: String) -> bool:
	for i in ticks:
		e.run(1)
		if not e.errors.is_empty():
			fail_test("%s: %s" % [msg, e.errors])
			return false
		var d := QA.rooms_vs_rebuild(e.ses)
		if not d.is_empty():
			fail_test("%s, tick %d: rooms differ from a full rebuild: %s" % [msg, e.t, d.slice(0, 3)])
			return false
		if cond.call():
			return true
	fail_test("%s not reached in %d ticks; jobs: %s" % [msg, ticks, e.jobs_text()])
	return false


func _room(p: Vector2i) -> Dictionary:
	return e.ses.rooms.room_at(p)


func test_rooms_follow_every_kind_of_npc_edit() -> void:
	var g := s.grid
	g.apply_edit(Rect2i(17, 10, 1, 8), WorldGrid.Edit.DIG)
	for y in range(10, 18):
		g.apply_structure(Vector2i(17, y), WorldGrid.Structure.LADDER)
	g.apply_edit(Rect2i(18, 15, 10, 3), WorldGrid.Edit.DIG)   # corridor + pocket, open via the shaft
	s.inventory.spawn_ground(&"rock", 800.0, Vector2i(3, 9))
	s.colony.spawn_npc(Vector2i(6, 9))
	s.colony.spawn_npc(Vector2i(8, 9))
	assert_eq(s.rooms.room_count(), 0, "pocket open to the sky through the shaft")

	# 1. Door closes the pocket -> a 24-tile room.
	assert_true(s.build_orders.order_building(&"door", Vector2i(19, 17)).ok)
	if not _step(4000, func() -> bool: return s.buildings.count() == 1, "door built"):
		return
	assert_eq(_room(Vector2i(22, 16)).get("size"), 24)
	assert_eq(_room(Vector2i(22, 16)).get("type"), &"room")
	# 2. Bed -> bedroom; 3. crate -> still bedroom (bed wins).
	assert_true(s.build_orders.order_building(&"bed", Vector2i(21, 17)).ok)
	assert_true(s.build_orders.order_building(&"crate", Vector2i(25, 17)).ok)
	if not _step(6000, func() -> bool: return s.buildings.count() == 3, "bed and crate built"):
		return
	assert_eq(_room(Vector2i(22, 16)).get("type"), &"bedroom")
	assert_eq(_room(Vector2i(22, 16)).get("building_ids").size(), 2)
	# 4. Interior door splits it: bed side 9 tiles, crate side 12 tiles.
	assert_true(s.build_orders.order_building(&"door", Vector2i(23, 17)).ok)
	if not _step(4000, func() -> bool: return s.buildings.count() == 4, "inner door built"):
		return
	assert_eq(_room(Vector2i(21, 16)).get("size"), 9)
	assert_eq(_room(Vector2i(21, 16)).get("type"), &"bedroom")
	assert_eq(_room(Vector2i(25, 16)).get("size"), 12)
	assert_eq(_room(Vector2i(25, 16)).get("type"), &"storage")
	# 5. Wall in the far corner shrinks the storage room; 6. deconstructing it restores it.
	assert_true(s.designations.designate(Rect2i(27, 15, 1, 1), K.BUILD_WALL).ok)
	if not _step(4000, func() -> bool: return g.get_tile(Vector2i(27, 15)) == TileRegistry.CONCRETE, "wall built"):
		return
	assert_eq(_room(Vector2i(25, 16)).get("size"), 11)
	assert_true(s.designations.designate(Rect2i(27, 15, 1, 1), K.DECONSTRUCT).ok)
	if not _step(4000, func() -> bool: return g.get_tile(Vector2i(27, 15)) == TileRegistry.AIR, "wall deconstructed"):
		return
	assert_eq(_room(Vector2i(25, 16)).get("size"), 12)
	# 7. Dig into the side wall: the room grows.
	assert_true(s.designations.designate(Rect2i(28, 16, 1, 1), K.DIG).ok)
	if not _step(4000, func() -> bool: return g.get_tile(Vector2i(28, 16)) == TileRegistry.AIR, "side tile dug"):
		return
	assert_eq(_room(Vector2i(25, 16)).get("size"), 13)
	# 8. Deconstruct the inner door: one bedroom of 9 + 3 + 13 tiles.
	assert_true(s.designations.designate(Rect2i(23, 15, 1, 3), K.DECONSTRUCT).ok)
	if not _step(4000, func() -> bool: return s.buildings.count() == 3, "inner door deconstructed"):
		return
	assert_eq(_room(Vector2i(25, 16)).get("size"), 25)
	assert_eq(_room(Vector2i(25, 16)).get("type"), &"bedroom")
	# 9. Buildings lost (floor dug out): crate, then bed -> plain room, +1 tile each.
	g.apply_edit(Rect2i(25, 18, 1, 1), WorldGrid.Edit.DIG)
	assert_eq(QA.rooms_vs_rebuild(s), [] as Array[String])
	assert_eq(_room(Vector2i(22, 16)).get("size"), 26)
	assert_eq(_room(Vector2i(22, 16)).get("type"), &"bedroom")
	g.apply_edit(Rect2i(21, 18, 1, 1), WorldGrid.Edit.DIG)
	assert_eq(QA.rooms_vs_rebuild(s), [] as Array[String])
	assert_eq(_room(Vector2i(22, 16)).get("size"), 27)
	assert_eq(_room(Vector2i(22, 16)).get("type"), &"room")
	# 10. Size limit: + 48 tiles still a room; + 80 more -> open cave (no room).
	g.apply_edit(Rect2i(20, 19, 8, 6), WorldGrid.Edit.DIG)
	assert_eq(_room(Vector2i(22, 16)).get("size"), 75)
	g.apply_edit(Rect2i(20, 25, 16, 5), WorldGrid.Edit.DIG)
	assert_eq(_room(Vector2i(22, 16)), {}, "155 tiles > 128: no room")
	assert_eq(QA.rooms_vs_rebuild(s), [] as Array[String])
	e.run(300)
	assert_eq(e.errors, [] as Array[String])


## Lead (c): rooms are rebuilt on load and equal the rooms before saving.
func test_rooms_rebuilt_on_load() -> void:
	var g := s.grid
	g.apply_edit(Rect2i(20, 15, 8, 3), WorldGrid.Edit.DIG)
	g.apply_edit(Rect2i(30, 15, 5, 3), WorldGrid.Edit.DIG)
	g.apply_edit(Rect2i(30, 20, 6, 3), WorldGrid.Edit.BUILD_WALL)  # (solid anyway)
	s.buildings.place(&"bed", Vector2i(21, 17), {&"dirt": 50.0})
	s.buildings.place(&"crate", Vector2i(31, 17), {&"rock": 50.0})
	assert_eq(s.rooms.room_count(), 2)
	var before := QA.room_signature(s.rooms)
	var errs: Array[String] = e.reload()
	assert_eq(errs, [] as Array[String], "comparator incl. rooms")
	assert_eq(QA.room_signature(e.ses.rooms), before, "same rooms after load")
	assert_eq(e.ses.rooms.room_at(Vector2i(22, 16)).get("type"), &"bedroom")
	assert_eq(e.ses.rooms.room_at(Vector2i(32, 16)).get("type"), &"storage")
