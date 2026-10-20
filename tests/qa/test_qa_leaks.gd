extends GutTest
## QA (M2): is a WorldSession — with its grid, systems, NPCs, jobs and items —
## really freed when the last reference is dropped? RefCounted cycles (e.g.
## JobManager <-> Colony, or a lambda that captures an owner and is connected
## to a signal of something that owner holds) would keep everything alive
## forever ("ObjectDB instances were leaked at exit").
## Checked with weakrefs after real play, after save/load, and through the
## game screen's "quit to menu" path.

const QA := preload("res://tools/qa_harness.gd")
const FS := preload("res://tests/helpers/fs_util.gd")
const MAIN := preload("res://src/presentation/main.gd")
const K := DesignationMap.Kind
const SIZE := Vector2i(96, 64)

var reg: TileRegistry
var dir: String


func before_all() -> void:
	reg = TileRegistry.load_default()


func before_each() -> void:
	dir = FS.temp_root("qa_leak")
	DirAccess.make_dir_recursive_absolute(dir)


func after_each() -> void:
	FS.rm_rf(dir)


## Weak references to the session and everything it owns (incl. one NPC, one
## job and one item instance).
func _weak_parts(s: WorldSession) -> Dictionary:
	var w := {
		"session": weakref(s), "grid": weakref(s.grid), "designations": weakref(s.designations),
		"inventory": weakref(s.inventory), "stockpiles": weakref(s.stockpiles), "nav": weakref(s.nav),
		"jobs": weakref(s.jobs), "colony": weakref(s.colony), "clock": weakref(s.clock), "ids": weakref(s.ids),
	}
	var npcs := s.colony.all_npcs()
	if not npcs.is_empty():
		w["npc"] = weakref(npcs[0])
	var js := s.jobs.all_jobs()
	if not js.is_empty():
		w["job"] = weakref(js[0])
	var items := s.inventory.all_items()
	if not items.is_empty():
		w["item"] = weakref(items[0])
	return w


func _alive(w: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for k: String in w:
		if (w[k] as WeakRef).get_ref() != null:
			out.append(k)
	return out


## Plays a session for a while (all job kinds active) and returns weakrefs;
## every strong reference dies with this function's locals.
func _play_and_forget(with_load: bool) -> Dictionary:
	var s := WorldSession.create_new({"id": "leak", "name": "Leak", "seed": 99, "preset": "custom",
			"size": SIZE, "gen_version": WorldGenerator.GEN_VERSION}, reg)
	var g := s.grid
	var cx := g.width / 2
	for x in range(cx - 6, cx - 2):
		s.stockpiles.designate(Rect2i(x, g.surface_y[x] - 1, 1, 1))
	for x in range(cx + 2, cx + 10):
		s.designations.designate(Rect2i(x, g.surface_y[x], 1, 1), K.DIG)
	s.designations.designate(Rect2i(cx + 12, g.surface_y[cx + 12] - 1, 1, 1), K.BUILD_LADDER)
	s.inventory.spawn_ground(&"rock", 120.0, Vector2i(cx, g.surface_y[cx] - 1))
	for tick in range(1, 400):
		s.clock.tick_index = tick
		s.simulate_tick(tick)
	if with_load:
		assert_true(SaveService.save(s, dir, SaveService.Kind.MANUAL).ok)
		var r := SaveService.load_world(dir, reg, s.meta)
		assert_true(r.ok)
		var l: WorldSession = r.data["session"]
		var wl := _weak_parts(l)
		for tick in range(400, 600):
			l.clock.tick_index = tick
			l.simulate_tick(tick)
		var w := _weak_parts(s)
		for k: String in wl:
			w["loaded_" + k] = wl[k]
		return w
	return _weak_parts(s)


func test_session_freed_after_play() -> void:
	var w := _play_and_forget(false)
	assert_true(w.has("npc") and w.has("item"), "fixture: NPCs and items existed")
	assert_eq(_alive(w), [] as Array[String], "nothing of the dropped session is still alive")


func test_session_and_loaded_session_freed() -> void:
	var w := _play_and_forget(true)
	assert_eq(_alive(w), [] as Array[String], "original and loaded sessions both freed")


func test_session_freed_after_quit_to_menu() -> void:
	var main := Node.new()
	main.set_script(MAIN)
	main.worlds_root = dir.path_join("worlds")
	add_child(main)
	await wait_process_frames(2)
	var w := await _game_round(main)
	await wait_process_frames(3)   # queue_free of the game screen happens here
	assert_true(main.current_screen is MainMenu, "back in the menu")
	assert_eq(_alive(w), [] as Array[String], "session freed after quit to menu")
	main.queue_free()
	await wait_process_frames(2)


func _game_round(main: Node) -> Dictionary:
	var r: CommandResult = main.slots.create_world("Leak World", 4242, &"small")
	assert_true(r.ok, str(r))
	var s: WorldSession = r.data["session"]
	var game: GameScreen = main.start_game(s)
	await wait_process_frames(3)
	var cx := s.grid.width / 2
	s.designations.designate(Rect2i(cx + 3, s.grid.surface_y[cx + 3], 3, 1), K.DIG)
	s.clock.set_speed(3)
	await wait_process_frames(30)
	var w := _weak_parts(s)
	w["game_screen"] = weakref(game)
	game.quit_to_menu()
	return w


## Diagnostic: object count before/after a full play-and-forget cycle.
func test_object_count_returns_to_baseline() -> void:
	var before := Performance.get_monitor(Performance.OBJECT_COUNT)
	for i in 2:
		_play_and_forget(i == 1)
	var after := Performance.get_monitor(Performance.OBJECT_COUNT)
	gut.p("objects before %d after %d (delta %d)" % [before, after, after - before])
	assert_true(after - before < 50, "object count back near baseline (delta %d)" % (after - before))


## The QA harness itself: a QA harness that connected a lambda capturing
## itself to a session signal (as test_dig_and_build_accounting_orders_only
## did) forms a cycle. Shows the harness without such lambdas is freed.
func test_qa_harness_freed() -> void:
	var w := _harness_round()
	assert_eq(_alive(w), [] as Array[String])


func _harness_round() -> Dictionary:
	var h := QA.new(reg, 5, SIZE, 5, 4)
	for i in 300:
		h.random_action()
		h.tick()
	var w := _weak_parts(h.s)
	w["harness"] = weakref(h)
	return w
