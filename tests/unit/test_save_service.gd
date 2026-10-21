extends GutTest

const FS := preload("res://tests/helpers/fs_util.gd")

var reg: TileRegistry
var dir: String


func before_all() -> void:
	reg = TileRegistry.load_default()


func before_each() -> void:
	dir = FS.temp_root("save")
	DirAccess.make_dir_recursive_absolute(dir)


func after_each() -> void:
	FS.rm_rf(dir)


func _session(world_seed: int = 7) -> WorldSession:
	return WorldSession.create_new({"id": "w1", "name": "T", "seed": world_seed, "preset": "custom",
			"size": Vector2i(96, 64), "gen_version": WorldGenerator.GEN_VERSION}, reg)


func _play(s: WorldSession, x: int) -> void:
	s.grid.apply_edit(Rect2i(x, 30, 6, 4), WorldGrid.Edit.DIG)
	s.designations.designate(Rect2i(x, 40, 3, 3), DesignationMap.Kind.DIG)
	s.clock.advance(1.0)
	s.ids.allocate(&"npc")


func _load(s: WorldSession) -> CommandResult:
	return SaveService.load_world(dir, reg, s.meta)


func test_round_trip_restores_everything() -> void:
	var s := _session()
	_play(s, 10)
	assert_true(SaveService.save(s, dir, SaveService.Kind.MANUAL).ok)
	var r := _load(s)
	assert_true(r.ok, str(r))
	var l: WorldSession = r.data["session"]
	assert_eq(l.grid.world_hash(), s.grid.world_hash())
	assert_eq(l.clock.tick_index, s.clock.tick_index)
	assert_eq(l.ids.peek_next(&"npc"), s.ids.peek_next(&"npc"))
	assert_eq(l.designations.to_snapshot(), s.designations.to_snapshot())
	assert_eq(l.grid.modified_chunks(), s.grid.modified_chunks(), "edited chunks stay tracked")
	assert_false(r.data["fell_back"])


func test_v2_round_trip_with_ladders_items_and_stockpiles() -> void:
	var s := _session()
	_play(s, 10)
	var air := Vector2i(50, s.grid.surface_y[50] - 1)
	assert_true(s.grid.apply_structure(air, WorldGrid.Structure.LADDER).ok)
	# Carrying mid-job is covered by tests/unit/test_colony_snapshot.gd; a carry
	# without a job is (correctly) undone by JobManager re-validation on load.
	s.inventory.spawn_ground(&"dirt", 50.0, Vector2i(10, 33))
	s.inventory.spawn_ground(&"rock", 30.0, Vector2i(11, 33))
	var floor_x := 60
	s.stockpiles.designate(Rect2i(floor_x, s.grid.surface_y[floor_x] - 1, 1, 1))
	assert_true(SaveService.save(s, dir, SaveService.Kind.MANUAL).ok)
	var r := _load(s)
	assert_true(r.ok, str(r))
	var l: WorldSession = r.data["session"]
	assert_eq(r.data["migrated_from"], SaveService.SAVE_VERSION)
	for k in r.data["dropped"]:
		assert_eq(r.data["dropped"][k], 0, "dropped %s" % k)
	assert_eq(l.colony.count(), s.colony.count())
	assert_true(l.grid.is_ladder(air))
	assert_eq(l.grid.world_hash(), s.grid.world_hash())
	assert_eq(l.inventory.to_snapshot(), s.inventory.to_snapshot())
	assert_eq(l.inventory.check_conservation(), [] as Array[String])
	assert_eq(l.jobs.check_invariants(), [] as Array[String])
	assert_eq(l.stockpiles.count(), 1)
	assert_eq(l.ids.peek_next(&"item"), s.ids.peek_next(&"item"), "item ids continue, never reused")


func test_v3_round_trip_buildings_crates_rooms() -> void:
	var s := _session()
	var x := 40
	var floor_y := s.grid.surface_y[x] - 1
	assert_true(s.buildings.place(&"crate", Vector2i(x, floor_y), {&"rock": 50.0}).ok)
	var crate_id := s.buildings.building_at(Vector2i(x, floor_y))
	assert_true(s.crates.set_filter(crate_id, [&"dirt"] as Array[StringName]).ok)
	var item := s.inventory.spawn_ground(&"dirt", 40.0, Vector2i(x, floor_y))
	s.inventory.pick_up(item, "npc:1")
	assert_true(s.inventory.store_in_crate("npc:1", crate_id).ok)
	var bed_order := s.build_orders.order_building(&"bed", Vector2i(x + 4, floor_y), 7)
	assert_true(bed_order.ok, str(bed_order))
	assert_true(SaveService.save(s, dir, SaveService.Kind.MANUAL).ok)
	var r := _load(s)
	assert_true(r.ok, str(r))
	assert_eq(r.data["migrated_from"], SaveService.SAVE_VERSION)
	for k in r.data["dropped"]:
		assert_eq(r.data["dropped"][k], 0, "dropped %s" % k)
	var l: WorldSession = r.data["session"]
	assert_eq(l.buildings.get_building(crate_id)["key"], &"crate")
	assert_eq(l.crates.get_filter(crate_id), [&"dirt"] as Array[StringName])
	assert_eq(l.inventory.crate_kg(crate_id), 40.0)
	assert_eq(l.grid.world_hash(), s.grid.world_hash())
	assert_eq(l.rooms.room_count(), s.rooms.room_count(), "rooms rebuilt on load")
	assert_eq(l.build_orders.orders(), s.build_orders.orders(), "building orders survive")
	assert_eq(l.jobs.check_invariants(), [] as Array[String])


## First tile >= from_x where `width` surface columns are level (origin = tile above the floor).
func _flat_spot(s: WorldSession, width: int, from_x: int) -> Vector2i:
	for x in range(from_x, s.grid.width - width - 1):
		var ok := true
		for i in width:
			ok = ok and s.grid.surface_y[x + i] == s.grid.surface_y[x]
		if ok:
			return Vector2i(x, s.grid.surface_y[x] - 1)
	return Vector2i(-1, -1)


func test_new_world_has_starting_rations() -> void:
	var s := _session()
	assert_almost_eq(float(s.inventory.total_kg_by_material().get(&"ration", 0.0)),
			WorldSession.STARTING_RATION_KG, 0.001)


func test_v4_round_trip_farming_and_kitchens() -> void:
	var s := _session()
	var farm_at := _flat_spot(s, 2, 5)
	var kitchen_at := _flat_spot(s, 2, farm_at.x + 3)
	assert_true(s.buildings.place(&"farm_plot", farm_at, {}).ok)
	assert_true(s.buildings.place(&"kitchen", kitchen_at, {}).ok)
	var farm := s.buildings.building_at(farm_at)
	var kitchen := s.buildings.building_at(kitchen_at)
	assert_true(s.farming.plant(farm).ok)
	for t in range(1, 101):
		s.farming.update(t)
	assert_true(s.kitchens.set_target_kg(kitchen, 25.0).ok)
	assert_true(SaveService.save(s, dir, SaveService.Kind.MANUAL).ok)
	var r := _load(s)
	assert_true(r.ok, str(r))
	for k in r.data["dropped"]:
		assert_eq(r.data["dropped"][k], 0, "dropped %s" % k)
	var l: WorldSession = r.data["session"]
	assert_eq(l.farming.stage(farm), Farming.Stage.GROWING)
	assert_almost_eq(l.farming.progress(farm), s.farming.progress(farm), 0.0001)
	assert_eq(l.kitchens.target_kg(kitchen), 25.0)


func test_orphan_crate_items_are_rescued() -> void:
	var s := _session()
	var item := s.inventory.spawn_ground(&"rock", 30.0, Vector2i(5, 5))
	s.inventory.pick_up(item, "npc:1")
	s.inventory.store_in_crate("npc:1", "bld:999")  # crate that does not exist
	SaveService.save(s, dir, SaveService.Kind.MANUAL)
	var r := _load(s)
	assert_true(r.ok)
	assert_eq(r.data["dropped"]["orphan_crate_items"], 1)
	var l: WorldSession = r.data["session"]
	assert_eq(l.inventory.crate_kg("bld:999"), 0.0)
	assert_eq(l.inventory.total_kg_by_material().get(&"rock", 0.0), 30.0, "nothing lost")


func test_v1_save_migrates() -> void:
	var s := _session()
	_play(s, 10)
	# Build what an M1 (v1) save looked like: tiles-only chunks, terrain hash, no inventory.
	var p := SaveService.build_payload(s)
	p["save_version"] = 1
	p.erase("inventory")
	p.erase("stockpiles")
	var v1_chunks := {}
	for idx in p["chunks"]:
		var b: PackedByteArray = p["chunks"][idx]
		v1_chunks[idx] = b.slice(0, b.size() / 2)
	p["chunks"] = v1_chunks
	p["world_hash"] = s.grid.terrain_hash()
	p["designations"].erase("priorities")
	assert_true(SaveService.write_atomic(dir.path_join("manual.save"), p).ok)
	var r := _load(s)
	assert_true(r.ok, str(r))
	assert_eq(r.data["migrated_from"], 1)
	var l: WorldSession = r.data["session"]
	assert_eq(l.grid.terrain_hash(), s.grid.terrain_hash())
	assert_eq(l.designations.count(), s.designations.count())
	assert_eq(l.inventory.all_items().size(), 0)
	assert_eq(l.colony.count(), Colony.START_NPCS, "migrated M1 world gets the starting colony")
	assert_eq(l.jobs.job_count(), l.designations.count(), "every old order becomes a job")
	assert_eq(l.jobs.check_invariants(), [] as Array[String])
	# Re-saving writes v2.
	assert_true(SaveService.save(l, dir, SaveService.Kind.AUTO).ok)
	assert_eq(SaveService.read_file(dir.path_join("autosave.save"))["payload"]["save_version"], SaveService.SAVE_VERSION)


func test_unknown_future_version_refused() -> void:
	var s := _session()
	var p := SaveService.build_payload(s)
	p["save_version"] = 99
	SaveService.write_atomic(dir.path_join("manual.save"), p)
	var r := _load(s)
	assert_false(r.ok)
	assert_string_contains(str(r.data["errors"]), "Unsupported save version")


func test_only_modified_chunks_are_stored() -> void:
	var s := _session()
	_play(s, 10)
	var chunks: Dictionary = SaveService.build_payload(s)["chunks"]
	assert_gt(chunks.size(), 0)
	assert_lt(chunks.size(), s.grid.chunk_count())
	assert_eq(chunks.size(), s.grid.modified_chunks().size())


func test_load_picks_newest_file() -> void:
	var s := _session()
	SaveService.save(s, dir, SaveService.Kind.MANUAL)
	_play(s, 40)
	SaveService.save(s, dir, SaveService.Kind.AUTO)
	var r := _load(s)
	assert_eq(r.data["source"], "autosave.save")
	assert_eq(r.data["session"].grid.world_hash(), s.grid.world_hash())


func test_interrupted_write_keeps_previous_save() -> void:
	var s := _session()
	_play(s, 10)
	SaveService.save(s, dir, SaveService.Kind.MANUAL)
	var good := s.grid.world_hash()
	FS.write_bytes(dir.path_join("manual.save.tmp"), "half-written".to_utf8_buffer())
	var r := _load(s)
	assert_true(r.ok)
	assert_eq(r.data["session"].grid.world_hash(), good)


func test_corrupt_save_falls_back_to_backup() -> void:
	var s := _session()
	_play(s, 10)
	SaveService.save(s, dir, SaveService.Kind.MANUAL)
	var v1 := s.grid.world_hash()
	_play(s, 50)
	SaveService.save(s, dir, SaveService.Kind.MANUAL)
	assert_true(FileAccess.file_exists(dir.path_join("manual.save.bak")))
	FS.write_bytes(dir.path_join("manual.save"), "garbage".to_utf8_buffer())
	var r := _load(s)
	assert_true(r.ok, str(r))
	assert_true(r.data["fell_back"])
	assert_eq(r.data["source"], "manual.save.bak")
	assert_eq(r.data["session"].grid.world_hash(), v1)


func test_all_saves_corrupt_fails_cleanly() -> void:
	var s := _session()
	SaveService.save(s, dir, SaveService.Kind.MANUAL)
	FS.write_bytes(dir.path_join("manual.save"), PackedByteArray([71, 67, 80, 70, 1, 2, 3]))
	var r := _load(s)
	assert_false(r.ok)
	assert_eq(r.code, &"no_valid_save")
	# Godot itself reports the damaged compressed block; we handle it.
	assert_engine_error("ERR_FILE_CORRUPT")


func test_generator_version_mismatch_refused() -> void:
	var s := _session()
	var p := SaveService.build_payload(s)
	p["gen_version"] = 999
	assert_true(SaveService.write_atomic(dir.path_join("manual.save"), p).ok)
	var r := _load(s)
	assert_false(r.ok)
	assert_string_contains(str(r.data["errors"]), "generator v999")


func test_tampered_world_detected() -> void:
	var s := _session()
	var p := SaveService.build_payload(s)
	p["world_hash"] = "not-the-real-hash"
	SaveService.write_atomic(dir.path_join("manual.save"), p)
	var r := _load(s)
	assert_false(r.ok)
	assert_string_contains(str(r.data["errors"]), "checksum")
