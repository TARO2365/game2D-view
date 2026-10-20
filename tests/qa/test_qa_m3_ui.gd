extends GutTest
## QA M3 criterion 8: the placement preview agrees with what
## BuildOrders.order_building accepts (randomized, in a world with orders,
## designations and buildings); Priority / Cancel / Deconstruct tools apply
## to building orders and buildings. Real GameScreen on a real temp world.

const FS := preload("res://tests/helpers/fs_util.gd")
const GAME := preload("res://scenes/game.tscn")
const K := DesignationMap.Kind
const KEYS: Array[StringName] = [&"crate", &"bed", &"table", &"door"]

var root: String
var slots: WorldSlots
var session: WorldSession
var game: GameScreen


func before_each() -> void:
	root = FS.temp_root("qa_m3_ui")
	slots = WorldSlots.new(TileRegistry.load_default(), root)
	session = slots.create_world("QA M3 UI", 31, &"small").data["session"]
	session.clock.set_speed(0)
	game = GAME.instantiate()
	game.setup(session, slots, load("res://data/config/scale_config.tres"))
	add_child_autofree(game)
	await wait_process_frames(2)


func after_each() -> void:
	FS.rm_rf(root)


## Clutter near the surface: dug pockets, walls (door supports), ladders,
## buildings, building orders and tile designations.
func _clutter(rng: RandomNumberGenerator) -> void:
	var g := session.grid
	var mid := g.width / 2
	for i in 25:
		var x := mid + rng.randi_range(-40, 40)
		var y: int = g.surface_y[x] + rng.randi_range(-3, 4)
		match rng.randi_range(0, 5):
			0:
				g.apply_edit(Rect2i(x, y, rng.randi_range(1, 4), 3), WorldGrid.Edit.DIG)
			1:
				g.apply_edit(Rect2i(x, y, rng.randi_range(1, 3), 1), WorldGrid.Edit.BUILD_WALL)
			2:
				g.apply_structure(Vector2i(x, y), WorldGrid.Structure.LADDER)
			3:
				session.buildings.place(KEYS[rng.randi_range(0, 2)], Vector2i(x, y), {&"rock": 50.0})
			4:
				session.build_orders.order_building(KEYS[rng.randi_range(0, 3)], Vector2i(x, y))
			5:
				session.designations.designate(Rect2i(x, y, 2, 1), K.BUILD_LADDER)


func test_preview_matches_order_building_randomized() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 808
	_clutter(rng)
	var g := session.grid
	var mid := g.width / 2
	var mismatches: Array[String] = []
	var accepted := 0
	for i in 3000:
		var key := KEYS[rng.randi_range(0, KEYS.size() - 1)]
		var x := mid + rng.randi_range(-45, 45)
		var o := Vector2i(x, g.surface_y[x] + rng.randi_range(-4, 5))
		game.start_placement(key)
		var preview := game.tools.update_preview(o)
		var r := session.build_orders.order_building(key, o, game.tools.priority)
		if preview.ok != r.ok or (not r.ok and preview.code != r.code):
			mismatches.append("%s at %s: preview %s/%s, order %s/%s" % [key, o, preview.ok, preview.code, r.ok, r.code])
		if r.ok:
			accepted += 1
			session.build_orders.remove(r.data["id"])   # keep the world as it was
	gut.p("preview vs order: %d probes, %d accepted, %d mismatches" % [3000, accepted, mismatches.size()])
	assert_gt(accepted, 50, "fixture: enough valid spots probed")
	assert_eq(mismatches, [] as Array[String])


## The preview is cached per origin: after the world changes under a
## motionless pointer it must not keep promising a placement that now fails.
## BUG M3-QA-5: confirmed failing without pending() on 2026-10-20: preview
## ok=true while order_building fails with overlaps_designation
## (ToolController.update_preview recomputes only when the origin changes).
func test_preview_refreshes_when_world_changes_under_pointer() -> void:
	pending("BUG M3-QA-5: placement preview stays green after the world changes under a motionless pointer")
	return
	@warning_ignore("unreachable_code")
	var g := session.grid
	var mid := g.width / 2
	var o := Vector2i(-1, -1)
	for off in range(4, 60):
		var t := Vector2i(mid + off, g.surface_y[mid + off] - 1)
		if session.buildings.can_place(&"crate", t).ok and session.build_orders.order_at(t).is_empty():
			o = t
			break
	game.start_placement(&"crate")
	assert_true(game.tools.update_preview(o).ok, "fixture: spot is valid")
	assert_true(session.designations.designate(Rect2i(o, Vector2i.ONE), K.BUILD_LADDER).ok)
	await wait_process_frames(2)
	var shown := game.tools.update_preview(o)
	var real := session.build_orders.order_building(&"crate", o)
	gut.p("after a ladder order under the pointer: preview ok=%s, order ok=%s (%s)" % [shown.ok, real.ok, real.code])
	assert_eq(shown.ok, real.ok, "preview still green while the order is refused")


func test_tools_apply_to_building_orders_and_buildings() -> void:
	var g := session.grid
	var mid := g.width / 2
	var spots: Array[Vector2i] = []
	for off in range(4, 80):
		var t := Vector2i(mid + off, g.surface_y[mid + off] - 1)
		if session.buildings.can_place(&"bed", t).ok and spots.size() < 2 \
				and (spots.is_empty() or absi(spots[0].x - t.x) > 3):
			spots.append(t)
	assert_eq(spots.size(), 2, "fixture spots")
	var a := spots[0]
	var b := spots[1]
	game.start_placement(&"bed")
	game.tools.set_priority(3)
	assert_true(game.tools.place_at(a).ok)
	assert_eq(session.build_orders.order_at(a)["priority"], 3, "placement uses the chosen priority")
	assert_eq(session.jobs.job_at(a).priority, 3, "job follows")
	# Priority tool on the footprint's second tile.
	game.set_tool(ToolController.Tool.PRIORITY)
	game.set_priority(8)
	assert_true(game.tools.apply_rect(Rect2i(a + Vector2i.RIGHT, Vector2i.ONE)).ok)
	assert_eq(session.build_orders.order_at(a)["priority"], 8)
	assert_eq(session.jobs.job_at(a).priority, 8, "job priority follows the order")
	# Deconstruct tool on an unbuilt order does nothing; Cancel removes it.
	game.set_tool(ToolController.Tool.DECONSTRUCT)
	assert_false(game.tools.apply_rect(Rect2i(a, Vector2i(2, 1))).ok)
	game.set_tool(ToolController.Tool.CANCEL)
	assert_true(game.tools.apply_rect(Rect2i(a, Vector2i.ONE)).ok)
	assert_eq(session.build_orders.count(), 0)
	assert_null(session.jobs.job_at(a))
	# A finished building: Cancel leaves it, Deconstruct designates its tiles,
	# Priority changes the deconstruct job, Cancel removes the deconstruct order.
	var bid: String = session.buildings.place(&"bed", b, {&"dirt": 50.0}).data["id"]
	game.set_tool(ToolController.Tool.CANCEL)
	game.tools.apply_rect(Rect2i(b, Vector2i(2, 1)))
	assert_false(session.buildings.get_building(bid).is_empty(), "Cancel never removes a building")
	game.set_tool(ToolController.Tool.DECONSTRUCT)
	game.set_priority(4)
	assert_true(game.tools.apply_rect(Rect2i(b, Vector2i(2, 1))).ok)
	var dj := session.jobs.job_at(b)
	assert_not_null(dj)
	assert_eq(dj.kind, Job.KIND_DECONSTRUCT)
	assert_eq(dj.priority, 4)
	game.set_tool(ToolController.Tool.PRIORITY)
	game.set_priority(9)
	assert_true(game.tools.apply_rect(Rect2i(b, Vector2i(2, 1))).ok)
	assert_eq(session.jobs.job_at(b).priority, 9)
	game.set_tool(ToolController.Tool.CANCEL)
	assert_true(game.tools.apply_rect(Rect2i(b, Vector2i(2, 1))).ok)
	assert_eq(session.designations.count(), 0)
	assert_eq(session.jobs.job_count(), 0)
	assert_false(session.buildings.get_building(bid).is_empty())
