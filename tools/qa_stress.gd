extends SceneTree
## QA long stress run (M2 acceptance 1, 3, 5, 6). Seeded random player actions
## every few ticks, invariants after EVERY tick, save/load at random moments
## (in memory; every 3rd one through the real atomic file writer + load_world).
## Usage:
##   godot --headless --path . -s res://tools/qa_stress.gd -- [ticks] [seeds] [first_seed] [npcs]
## Defaults: 20000 ticks, 5 seeds, first seed 1, 8 NPCs. 5th arg "m3" adds M3 actions (buildings,
## deconstruct, crate filters) and compares rooms with a full rebuild every 50 ticks; "m4a" adds
## M4a actions on top (food, farms, kitchens, schedules, beds, need spikes). Exit 1 on any error.

const QA := preload("res://tools/qa_harness.gd")
const SIZE := Vector2i(128, 96)


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var ticks := int(args[0]) if args.size() > 0 else 20000
	var seeds := int(args[1]) if args.size() > 1 else 5
	var first := int(args[2]) if args.size() > 2 else 1
	var npcs := int(args[3]) if args.size() > 3 else 8
	var m4a := args.size() > 4 and args[4] == "m4a"
	var m3 := m4a or (args.size() > 4 and args[4] == "m3")
	var reg := TileRegistry.load_default()
	var failed := false
	var dir := "user://qa_stress_%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(dir)
	for sd in range(first, first + seeds):
		var h := QA.new(reg, 1000 + sd, SIZE, sd, npcs)
		if m3:
			if m4a:
				h.enable_m4a()
			else:
				h.enable_m3()
		var next_action := 1
		var next_save := h.rng.randi_range(500, 3000)
		var errs: Array[String] = []
		var first_err_tick := -1
		var t0 := Time.get_ticks_msec()
		var progress_at_load := 0.0
		var progress_after_loads: Array[float] = []
		var load_progress_start := -1.0
		for i in ticks:
			if h.now() >= next_action:
				h.random_action()
				next_action = h.now() + h.rng.randi_range(1, 12)
			h.tick()
			var e := h.check_all()
			if m3 and e.is_empty() and h.now() % 50 == 0:
				e = QA.rooms_vs_rebuild(h.s)
			if e.is_empty() and h.now() >= next_save:
				if load_progress_start >= 0.0:
					progress_after_loads.append(h.progress_kg() - load_progress_start)
				e = h.save_load(dir if h.loads_done % 3 == 2 else "")
				load_progress_start = h.progress_kg()
				next_save = h.now() + h.rng.randi_range(500, 3000)
			if not e.is_empty():
				errs = e
				first_err_tick = h.now()
				break
		var ms := Time.get_ticks_msec() - t0
		var line := "seed %d: ticks %d actions %d loads %d npcs %d jobs %d orders %d items %d progress %.0f kg  avg %.3f ms/tick max %.1f ms  wall %.1f s  stuck %d" % [
				sd, h.ticks_run, h.actions_run, h.loads_done, h.s.colony.count(), h.s.jobs.job_count(),
				h.s.designations.count(), h.s.inventory.all_items().size(), h.progress_kg(),
				h.total_tick_usec / 1000.0 / maxi(1, h.ticks_run), h.max_tick_usec / 1000.0, ms / 1000.0,
				h.stuck_reports.size()]
		print(line)
		if m3:
			if m4a:
				print("  m4a: deaths %d  alive %d  eaten %s  alerts %d" % [h.s.colony.deaths(), h.s.colony.count(), h.s.inventory.consumed_kg_by_material(), h.s.alerts.count()])
			print("  m3: ever placed %d of %d orders; now buildings %d (crates %d) building orders %d rooms %d crate kg %.0f" % [h.s.ids.peek_next(&"bld") - 1, h.s.ids.peek_next(&"bord") - 1, h.s.buildings.count(),
					h.s.crates.crate_ids().size(), h.s.build_orders.count(), h.s.rooms.room_count(), _crate_kg(h)])
		print("  progress (kg dug+built) in each segment between loads: %s" % [progress_after_loads])
		for st in h.stuck_reports.slice(0, 5):
			print("  STUCK " + st)
		if not errs.is_empty():
			failed = true
			print("  FAIL at tick %d: %s" % [first_err_tick, errs.slice(0, 6)])
			print("  last actions:\n" + h.recent_log())
	_rm(dir)
	print("RESULT: %s" % ("FAIL" if failed else "OK"))
	quit(1 if failed else 0)


func _rm(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)


func _crate_kg(h: Variant) -> float:
	var sum := 0.0
	for cid in h.s.crates.crate_ids():
		sum += h.s.inventory.crate_kg(cid)
	return sum
