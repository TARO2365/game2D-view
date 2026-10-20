extends GutTest
## Thai NPC names: pool sizes, Thai script, uniqueness within a colony,
## per-world seeded (same seed -> same names).

const FS := preload("res://tests/helpers/fs_util.gd")

var reg: TileRegistry


func before_all() -> void:
	reg = TileRegistry.load_default()


func _colony(world_seed: int) -> Colony:
	var g := FS.make_grid(reg, Vector2i(40, 30))
	var ids := StableIdAllocator.new()
	var des := DesignationMap.new(g)
	var inv := Inventory.new(ids)
	var sp := StockpileZones.new(g, inv)
	var nav := NavGrid.new(g, 3)
	var jobs := JobManager.new(g, des, inv, sp, nav, ids)
	return Colony.new(g, nav, jobs, ids, world_seed)


func _is_thai(s: String) -> bool:
	for i in s.length():
		var c := s.unicode_at(i)
		if c < 0x0E00 or c > 0x0E7F:
			return false
	return not s.is_empty()


func test_pools() -> void:
	for pool: Array[String] in [ThaiNames.GIVEN_NAMES, ThaiNames.SURNAMES, ThaiNames.NICKNAMES]:
		assert_gte(pool.size(), 40)
		var seen := {}
		for s in pool:
			assert_true(_is_thai(s), "'%s' is Thai script" % s)
			assert_false(seen.has(s), "'%s' listed twice" % s)
			seen[s] = true


func test_unique_names_for_100_npcs() -> void:
	var col := _colony(777)
	var full := {}
	var nick := {}
	for i in 100:
		var n := col.spawn_npc(Vector2i(i % 40, 9))
		assert_false(full.has(n.full_name), "full name %s unique" % n.full_name)
		assert_false(nick.has(n.nickname), "nickname %s unique" % n.nickname)
		full[n.full_name] = true
		nick[n.nickname] = true
		assert_true(n.full_name.contains(" "), "given name + surname")
	assert_eq(full.size(), 100)
	assert_eq(nick.size(), 100)


func test_names_seeded_per_world() -> void:
	var a := _colony(12345)
	var b := _colony(12345)
	var c := _colony(54321)
	var same := true
	var differs := false
	for i in 5:
		var na := a.spawn_npc(Vector2i(5 + i, 9))
		var nb := b.spawn_npc(Vector2i(5 + i, 9))
		var nc := c.spawn_npc(Vector2i(5 + i, 9))
		same = same and na.full_name == nb.full_name and na.nickname == nb.nickname
		differs = differs or na.full_name != nc.full_name
	assert_true(same, "same world seed -> same names")
	assert_true(differs, "other seed -> other names")


func test_names_survive_snapshot_and_stay_unique() -> void:
	var a := _colony(9)
	for i in 3:
		a.spawn_npc(Vector2i(5 + i, 9))
	var snap: Dictionary = bytes_to_var(var_to_bytes(a.to_snapshot()))
	var b := _colony(9)
	assert_eq(b.load_snapshot(snap), 0)
	assert_eq(b.count(), 3)
	for n in a.all_npcs():
		assert_eq(b.get_npc(n.id).full_name, n.full_name)
	# New NPCs after load do not repeat names.
	var names := {}
	for n in b.all_npcs():
		names[n.nickname] = true
	for i in 10:
		var n := b.spawn_npc(Vector2i(10 + i, 9))
		assert_false(names.has(n.nickname))
		names[n.nickname] = true
