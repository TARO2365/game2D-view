extends GutTest
## QA (M2 acceptance 1, 3, 5, 6): seeded random player actions every 1-12
## ticks (orders, cancels, priorities, stockpile add/remove, Move here, Stop,
## work toggles, terrain removed under NPCs and stockpiles, walls dropped onto
## NPCs/items via apply_edit, ladders removed, items and NPCs added).
## Invariants are checked after EVERY tick; the run is saved/loaded at random
## moments (in memory and through the real save files) and must restore the
## exact same state. The long version (20k ticks x 5 seeds) is
## tools/qa_stress.gd; this in-suite version keeps the run time moderate.

const QA := preload("res://tools/qa_harness.gd")
const FS := preload("res://tests/helpers/fs_util.gd")
const SIZE := Vector2i(128, 96)
const TICKS := 3000

var reg: TileRegistry
var dir: String


func before_all() -> void:
	reg = TileRegistry.load_default()


func before_each() -> void:
	dir = FS.temp_root("qa_stress")
	DirAccess.make_dir_recursive_absolute(dir)


func after_each() -> void:
	FS.rm_rf(dir)


func _stress(rng_seed: int, npcs: int) -> void:
	var h := QA.new(reg, 500 + rng_seed, SIZE, rng_seed, npcs)
	var next_action := 1
	var next_save := h.rng.randi_range(300, 1200)
	for i in TICKS:
		if h.now() >= next_action:
			h.random_action()
			next_action = h.now() + h.rng.randi_range(1, 12)
		h.tick()
		var errs := h.check_all()
		if errs.is_empty() and h.now() >= next_save:
			errs = h.save_load(dir if h.loads_done % 2 == 1 else "")
			next_save = h.now() + h.rng.randi_range(300, 1200)
		if not errs.is_empty():
			fail_test("seed %d tick %d: %s\nlast actions:\n%s" % [rng_seed, h.now(), errs.slice(0, 6), h.recent_log()])
			return
	assert_gt(h.loads_done, 1, "saved/loaded mid-run")
	assert_gt(h.progress_kg(), 0.0, "work got done")
	gut.p("seed %d: actions %d loads %d npcs %d jobs %d items %d progress %.0f kg avg %.3f ms max %.1f ms stuck %d" % [
			rng_seed, h.actions_run, h.loads_done, h.s.colony.count(), h.s.jobs.job_count(),
			h.s.inventory.all_items().size(), h.progress_kg(), h.total_tick_usec / 1000.0 / h.ticks_run,
			h.max_tick_usec / 1000.0, h.stuck_reports.size()])
	for st in h.stuck_reports:
		gut.p("  " + st)


## Acceptance 2: with only player orders (no dev terrain edits, no QA item
## spawns), every tile that turned solid -> air was a dig order and produced
## exactly one drop of its TileDef.drop_kg; every new ladder / wall consumed
## exactly its recipe kg. Terrain is compared tile by tile before/after.
func test_dig_and_build_accounting_orders_only() -> void:
	var h := QA.new(reg, 777, SIZE, 21, 10)
	h.action_weights = {"dig": 10, "ladder": 4, "wall": 3, "cancel": 2, "priority": 2,
			"stock_add": 2, "move": 2, "stop": 2, "toggle": 1}
	var before_tiles := h.s.grid.tiles.duplicate()
	var before_struct := h.s.grid.structures.duplicate()
	var ordered := {}  # tile index -> kinds ever ordered there
	# NOTE: this lambda captures h, and is connected to a signal of an object h
	# owns -> a RefCounted cycle. It MUST be disconnected again (it caused the
	# "526 ObjectDB instances were leaked at exit" of run_stress.ps1; QA-10).
	var on_orders := func(_r: Rect2i) -> void:
		for idx: int in h.s.designations.entries():
			ordered[idx] = true
	h.s.designations.designations_changed.connect(on_orders)
	var next_action := 1
	var failed := ""
	for i in 6000:
		if h.now() >= next_action:
			h.random_action()
			next_action = h.now() + h.rng.randi_range(1, 12)
		h.tick()
		if i % 5 == 0:
			var errs := h.check_all()
			if not errs.is_empty():
				failed = "tick %d: %s\n%s" % [h.now(), errs.slice(0, 5), h.recent_log()]
				break
	h.s.designations.designations_changed.disconnect(on_orders)
	if not failed.is_empty():
		fail_test(failed)
		return
	var g := h.s.grid
	var expect_spawn := {}
	var dug := 0
	var ladders := 0
	var walls := 0
	var unordered := 0
	for idx in g.tiles.size():
		var a := before_tiles[idx]
		var b := g.tiles[idx]
		if a != b or before_struct[idx] != g.structures[idx]:
			if not ordered.has(idx):
				unordered += 1
		if a != b and b == TileRegistry.AIR:
			dug += 1
			var def := reg.get_def(a)
			if def.drop_kg > 0.0:
				expect_spawn[def.key] = float(expect_spawn.get(def.key, 0.0)) + def.drop_kg
		elif a == TileRegistry.AIR and b == TileRegistry.CONCRETE:
			walls += 1
		if before_struct[idx] == WorldGrid.Structure.NONE and g.structures[idx] == WorldGrid.Structure.LADDER:
			ladders += 1
	assert_eq(unordered, 0, "terrain changed only where the player ordered")
	var spawned := h.s.inventory.spawned_kg_by_material()
	for m in expect_spawn:
		assert_almost_eq(float(spawned.get(m, 0.0)), float(expect_spawn[m]), 0.001, "drops of %s" % m)
	for m in spawned:
		# Lead (M4a): food (starting rations, harvests, meals) is spawned by design, not by digging.
		if h.s.materials.is_food(m):
			continue
		assert_true(expect_spawn.has(m), "no %s spawned without a dug tile" % m)
	var consumed := 0.0
	for v in h.s.inventory.consumed_kg_by_material().values():
		consumed += float(v)
	assert_almost_eq(consumed, walls * 50.0 + ladders * 25.0, 0.001, "builds consumed recipe kg")
	assert_gt(dug, 10, "work happened")
	gut.p("accounting: dug %d, ladders %d, walls %d, spawned %s, consumed %.0f" % [dug, ladders, walls, spawned, consumed])


func test_random_actions_seed_11() -> void:
	_stress(11, 6)


func test_random_actions_seed_12() -> void:
	_stress(12, 12)


func test_random_actions_seed_13_many_npcs_few_jobs() -> void:
	_stress(13, 24)
