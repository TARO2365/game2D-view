extends GutTest
## QA M3 stress: the M2 random player actions plus building orders (crate,
## bed, table, door), deconstruct of buildings/walls/ladders, crate filters,
## cancel/priority of building orders, rooms carved out and floors dug from
## under buildings. Invariants (incl. QA M3 invariants) after EVERY tick,
## incremental rooms == full rebuild every 25 ticks, save/load at random
## moments (memory + real files) with buildings/orders/filters/crate kg/rooms
## compared. Long version: tools/qa_stress.gd -- 20000 5 1 8 m3.
## Known bug M3-QA-2 (stale tile-index entry only) is tolerated here.

const QA := preload("res://tools/qa_harness.gd")
const FS := preload("res://tests/helpers/fs_util.gd")
const SIZE := Vector2i(128, 96)
const TICKS := 3000

var reg: TileRegistry
var dir: String


func before_all() -> void:
	reg = TileRegistry.load_default()
	QA.tolerate_stale_tile_index = true


func after_all() -> void:
	QA.tolerate_stale_tile_index = false


func before_each() -> void:
	dir = FS.temp_root("qa_m3_stress")
	DirAccess.make_dir_recursive_absolute(dir)


func after_each() -> void:
	FS.rm_rf(dir)


func _stress(rng_seed: int, npcs: int) -> void:
	var h := QA.new(reg, 700 + rng_seed, SIZE, rng_seed, npcs)
	h.enable_m3()
	var next_action := 1
	var next_save := h.rng.randi_range(300, 1000)
	var max_buildings := 0
	var max_rooms := 0
	for i in TICKS:
		if h.now() >= next_action:
			h.random_action()
			next_action = h.now() + h.rng.randi_range(1, 8)
		h.tick()
		var errs := h.check_all()
		if errs.is_empty() and h.now() % 25 == 0:
			errs = QA.rooms_vs_rebuild(h.s)
		if errs.is_empty() and h.now() >= next_save:
			errs = h.save_load(dir if h.loads_done % 2 == 1 else "")
			next_save = h.now() + h.rng.randi_range(300, 1000)
		if not errs.is_empty():
			fail_test("seed %d tick %d: %s\nlast actions:\n%s" % [rng_seed, h.now(), errs.slice(0, 6), h.recent_log()])
			return
		max_buildings = maxi(max_buildings, h.s.buildings.count())
		max_rooms = maxi(max_rooms, h.s.rooms.room_count())
	var placed := h.s.ids.peek_next(&"bld") - 1
	gut.p("M3 seed %d: actions %d loads %d buildings placed %d (max alive %d) building orders %d rooms max %d progress %.0f kg avg %.3f ms max %.1f ms" % [
			rng_seed, h.actions_run, h.loads_done, placed, max_buildings, h.s.ids.peek_next(&"bord") - 1,
			max_rooms, h.progress_kg(), h.total_tick_usec / 1000.0 / h.ticks_run, h.max_tick_usec / 1000.0])
	assert_gt(h.loads_done, 1, "saved/loaded mid-run")
	assert_gt(placed, 0, "buildings were built by NPCs")
	assert_gt(max_rooms, 0, "rooms existed")


func test_m3_random_actions_seed_21() -> void:
	_stress(21, 6)


func test_m3_random_actions_seed_22() -> void:
	_stress(22, 12)


func test_m3_random_actions_seed_23() -> void:
	_stress(23, 20)
