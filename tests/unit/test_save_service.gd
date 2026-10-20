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
	assert_eq(l.ids.peek_next(&"npc"), 2)
	assert_eq(l.designations.to_snapshot(), s.designations.to_snapshot())
	assert_eq(l.grid.modified_chunks(), s.grid.modified_chunks(), "edited chunks stay tracked")
	assert_false(r.data["fell_back"])


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
