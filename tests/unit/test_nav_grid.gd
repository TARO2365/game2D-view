extends GutTest
## NavGrid stand rules, every move type, path search and budget.
## Grid from fs_util.make_grid: rows < 10 air, rows 10..62 dirt, row 63 bedrock,
## so the surface feet row is y = 9.

const FS := preload("res://tests/helpers/fs_util.gd")

var reg: TileRegistry
var g: WorldGrid
var nav: NavGrid


func before_all() -> void:
	reg = TileRegistry.load_default()


func before_each() -> void:
	g = FS.make_grid(reg)
	nav = NavGrid.new(g, 3)


func _dig(x: int, y0: int, y1: int) -> void:
	assert_true(g.apply_edit(Rect2i(x, y0, 1, y1 - y0 + 1), WorldGrid.Edit.DIG).ok)


func _wall(p: Vector2i) -> void:
	g.tiles[p.y * g.width + p.x] = TileRegistry.DIRT
	nav.invalidate_all()


func test_stand_rules() -> void:
	assert_true(nav.can_stand(Vector2i(5, 9)), "air body, dirt floor")
	assert_false(nav.can_stand(Vector2i(5, 8)), "no floor")
	assert_false(nav.can_stand(Vector2i(5, 10)), "feet in solid")
	assert_false(nav.can_stand(Vector2i(5, 1)), "head out of the world")
	assert_false(nav.can_stand(Vector2i(-1, 9)))
	assert_false(nav.can_stand(Vector2i(64, 9)))
	_wall(Vector2i(5, 7))
	assert_false(nav.can_stand(Vector2i(5, 9)), "clearance 3 blocked at head height")
	assert_true(nav.can_stand(Vector2i(4, 9)))


func test_clearance_is_a_parameter() -> void:
	var small := NavGrid.new(g, 1)
	_wall(Vector2i(5, 8))
	assert_false(nav.can_stand(Vector2i(5, 9)))
	assert_true(small.can_stand(Vector2i(5, 9)), "clearance 1 only needs the feet tile")


func test_walk_moves() -> void:
	var nb := nav.neighbors(Vector2i(5, 9))
	assert_true(nb.has(Vector2i(4, 9)))
	assert_true(nb.has(Vector2i(6, 9)))
	assert_eq(nb.size(), 2, "flat ground: only walking")
	assert_eq(nav.move_cost(Vector2i(5, 9), Vector2i(6, 9)), NavGrid.TICKS_PER_STEP)
	assert_eq(nav.move_cost(Vector2i(5, 9), Vector2i(7, 9)), -1, "no jumps")


func test_step_up_needs_headroom() -> void:
	_wall(Vector2i(6, 9))
	assert_true(nav.can_stand(Vector2i(6, 8)))
	assert_true(nav.neighbors(Vector2i(5, 9)).has(Vector2i(6, 8)))
	assert_eq(nav.move_cost(Vector2i(5, 9), Vector2i(6, 8)), NavGrid.TICKS_PER_STEP)
	_wall(Vector2i(5, 6))  # directly above the head of an NPC at (5, 9)
	assert_true(nav.can_stand(Vector2i(5, 9)))
	assert_false(nav.neighbors(Vector2i(5, 9)).has(Vector2i(6, 8)), "no headroom")
	# Two tiles up is a wall climb: never allowed.
	_wall(Vector2i(4, 9))
	_wall(Vector2i(4, 8))
	assert_false(nav.neighbors(Vector2i(5, 9)).has(Vector2i(4, 7)))


func test_step_down() -> void:
	_dig(6, 10, 10)
	assert_true(nav.can_stand(Vector2i(6, 10)))
	assert_true(nav.neighbors(Vector2i(5, 9)).has(Vector2i(6, 10)))
	assert_eq(nav.move_cost(Vector2i(5, 9), Vector2i(6, 10)), NavGrid.TICKS_PER_STEP)
	assert_true(nav.neighbors(Vector2i(6, 10)).has(Vector2i(5, 9)), "and back up")


func test_drop_up_to_four() -> void:
	_dig(6, 10, 13)  # floor at 14 -> feet 13, a 4-tile drop
	var nb := nav.neighbors(Vector2i(5, 9))
	assert_true(nb.has(Vector2i(6, 13)))
	assert_eq(nav.move_cost(Vector2i(5, 9), Vector2i(6, 13)), NavGrid.TICKS_PER_DROP_TILE * 4)
	assert_false(nav.neighbors(Vector2i(6, 13)).has(Vector2i(5, 9)), "cannot climb back")


func test_drop_more_than_four_forbidden() -> void:
	_dig(6, 10, 14)  # 5-tile drop
	assert_true(nav.can_stand(Vector2i(6, 14)))
	assert_false(nav.neighbors(Vector2i(5, 9)).has(Vector2i(6, 14)))
	assert_eq(nav.move_cost(Vector2i(5, 9), Vector2i(6, 14)), -1)


func test_drop_needs_free_column() -> void:
	_dig(6, 10, 12)
	_wall(Vector2i(6, 7))  # side column blocked at head height
	assert_false(nav.neighbors(Vector2i(5, 9)).has(Vector2i(6, 12)))


func test_ladder_moves() -> void:
	_dig(5, 10, 15)  # shaft, bottom feet (5, 15)
	assert_eq(nav.find_path(Vector2i(5, 15), [Vector2i(20, 9)] as Array[Vector2i]), [] as Array[Vector2i],
			"no way out without ladders")
	for y in range(10, 16):
		assert_true(g.apply_structure(Vector2i(5, y), WorldGrid.Structure.LADDER).ok)
	assert_true(nav.can_stand(Vector2i(5, 12)), "standing on a ladder mid-shaft")
	assert_true(nav.neighbors(Vector2i(5, 9)).has(Vector2i(5, 10)), "climb down onto the ladder")
	assert_true(nav.neighbors(Vector2i(5, 15)).has(Vector2i(5, 14)))
	assert_eq(nav.move_cost(Vector2i(5, 13), Vector2i(5, 12)), NavGrid.TICKS_PER_LADDER_STEP)
	var path := nav.find_path(Vector2i(5, 15), [Vector2i(20, 9)] as Array[Vector2i])
	assert_false(path.is_empty())
	assert_eq(path[path.size() - 1], Vector2i(20, 9))
	# Every step of the path is a legal move.
	var cur := Vector2i(5, 15)
	for p in path:
		assert_gt(nav.move_cost(cur, p), 0, "step %s -> %s" % [cur, p])
		cur = p


func test_no_vertical_move_without_ladder() -> void:
	_dig(5, 10, 11)
	assert_false(nav.neighbors(Vector2i(5, 11)).has(Vector2i(5, 10)))


func test_path_basics() -> void:
	var path := nav.find_path(Vector2i(2, 9), [Vector2i(10, 9)] as Array[Vector2i])
	assert_eq(path.size(), 8)
	assert_eq(path[0], Vector2i(3, 9))
	assert_eq(path[7], Vector2i(10, 9))
	assert_eq(nav.find_path(Vector2i(2, 9), [Vector2i(2, 9)] as Array[Vector2i]).size(), 0,
			"already at the goal")
	assert_eq(nav.find_path(Vector2i(2, 9), [] as Array[Vector2i]).size(), 0)
	var multi := nav.find_path(Vector2i(2, 9), [Vector2i(30, 9), Vector2i(5, 9)] as Array[Vector2i])
	assert_eq(multi[multi.size() - 1], Vector2i(5, 9), "nearest goal")


func test_no_path_and_expansion_limit() -> void:
	_dig(5, 10, 12)  # 3-deep pit, no ladder
	assert_eq(nav.find_path(Vector2i(5, 12), [Vector2i(30, 9)] as Array[Vector2i]).size(), 0)
	assert_eq(nav.find_path(Vector2i(2, 9), [Vector2i(30, 9)] as Array[Vector2i]).size(), 0,
			"no jumping over the pit")
	assert_eq(nav.find_path(Vector2i(6, 9), [Vector2i(60, 9)] as Array[Vector2i], 5).size(), 0,
			"expansion budget too small")
	assert_lte(nav.last_expansions, 6)
	assert_eq(nav.find_path(Vector2i(6, 9), [Vector2i(60, 9)] as Array[Vector2i]).size(), 54)


func test_path_budget_per_tick() -> void:
	for i in NavGrid.PATH_BUDGET_PER_TICK:
		assert_true(nav.consume_budget(7))
	assert_false(nav.consume_budget(7), "budget exhausted this tick")
	assert_eq(nav.budget_left(7), 0)
	assert_eq(nav.budget_left(8), NavGrid.PATH_BUDGET_PER_TICK)
	assert_true(nav.consume_budget(8), "new tick, new budget")
	assert_eq(nav.budget_used(8), 1)


func test_cache_follows_terrain_changes() -> void:
	assert_true(nav.can_stand(Vector2i(5, 9)))
	_dig(5, 10, 10)
	assert_false(nav.can_stand(Vector2i(5, 9)), "floor dug away")
	assert_true(nav.can_stand(Vector2i(5, 10)))
	assert_true(g.apply_edit(Rect2i(5, 9, 1, 1), WorldGrid.Edit.BUILD_WALL).ok)
	assert_false(nav.can_stand(Vector2i(5, 10)), "wall in the body")
	assert_true(nav.can_stand(Vector2i(5, 8)))
