extends GutTest

const FS := preload("res://tests/helpers/fs_util.gd")

var reg: TileRegistry
var root: String
var slots: WorldSlots


func before_all() -> void:
	reg = TileRegistry.load_default()


func before_each() -> void:
	root = FS.temp_root("slots")
	slots = WorldSlots.new(reg, root)


func after_each() -> void:
	FS.rm_rf(root)


func test_max_three_worlds_then_delete_frees_slot() -> void:
	for i in 3:
		var r := slots.create_world("W%d" % i, i, &"small")
		assert_true(r.ok, str(r))
	assert_false(slots.can_create())
	var fourth := slots.create_world("W4", 9, &"small")
	assert_false(fourth.ok)
	assert_eq(fourth.code, &"world_limit")
	assert_eq(slots.count(), 3)
	var id: String = slots.list_worlds()[0]["id"]
	assert_true(slots.delete_world(id).ok)
	assert_false(DirAccess.dir_exists_absolute(slots.world_dir(id)))
	assert_true(slots.can_create())


func test_name_rules() -> void:
	assert_eq(slots.create_world("   ", 1, &"small").code, &"name_required")
	assert_eq(slots.create_world("x".repeat(33), 1, &"small").code, &"name_too_long")
	assert_true(slots.create_world("Alpha", 1, &"small").ok)
	assert_eq(slots.create_world("alpha", 2, &"small").code, &"name_taken")
	assert_eq(slots.create_world("Beta", 2, &"huge").code, &"invalid_preset")
	assert_eq(slots.suggest_name(), "World 1")


func test_meta_round_trip_and_load() -> void:
	var r := slots.create_world("Gamma", 4242, &"small")
	var id: String = r.data["id"]
	var m := slots.read_meta(id)
	assert_eq(m["name"], "Gamma")
	assert_eq(m["seed"], 4242)
	assert_eq(m["size"], WorldGenerator.PRESETS[&"small"])
	var loaded := slots.load_world(id)
	assert_true(loaded.ok, str(loaded))
	assert_eq(loaded.data["session"].grid.world_hash(), r.data["session"].grid.world_hash())


func test_list_sorted_by_last_played() -> void:
	var a: String = slots.create_world("A", 1, &"small").data["id"]
	var b: String = slots.create_world("B", 2, &"small").data["id"]
	var ma := slots.read_meta(a)
	ma["last_played_unix"] = 9999999999.0
	slots.write_meta(ma)
	assert_eq(slots.list_worlds()[0]["id"], a)
	assert_eq(slots.list_worlds()[1]["id"], b)


func test_delete_rejects_unknown_and_unsafe_ids() -> void:
	assert_eq(slots.delete_world("w123").code, &"unknown_world")
	assert_eq(slots.delete_world("../etc").code, &"unknown_world")
	assert_eq(slots.load_world("nope").code, &"unknown_world")
