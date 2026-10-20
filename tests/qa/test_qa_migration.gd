extends GutTest
## QA (M2 acceptance 6): an M1 (save v1) world full of dig orders loads via
## migration, gets the starting colony, and the NPCs then actually work the
## orders: reachable ones get dug, buried ones are shown unreachable (not held
## silently). Uses the real save files (write_atomic + load_world).

const QA := preload("res://tools/qa_harness.gd")
const FS := preload("res://tests/helpers/fs_util.gd")
const K := DesignationMap.Kind
const SIZE := Vector2i(128, 96)

var reg: TileRegistry
var dir: String


func before_all() -> void:
	reg = TileRegistry.load_default()


func before_each() -> void:
	dir = FS.temp_root("qa_v1")
	DirAccess.make_dir_recursive_absolute(dir)


func after_each() -> void:
	FS.rm_rf(dir)


## Payload exactly as an M1 build wrote it: tiles-only chunks, terrain hash,
## designations without priorities, no inventory/stockpiles/colony/jobs.
func _v1_payload(s: WorldSession) -> Dictionary:
	var p := SaveService.build_payload(s)
	p["save_version"] = 1
	for k: String in ["inventory", "stockpiles", "colony", "jobs"]:
		p.erase(k)
	var v1_chunks := {}
	for idx in p["chunks"]:
		var b: PackedByteArray = p["chunks"][idx]
		v1_chunks[idx] = b.slice(0, b.size() / 2)
	p["chunks"] = v1_chunks
	p["world_hash"] = s.grid.terrain_hash()
	p["designations"].erase("priorities")
	return p


func test_v1_world_with_many_dig_orders_is_worked_after_migration() -> void:
	var meta := {"id": "m1", "name": "M1", "seed": 31337, "preset": "custom", "size": SIZE,
			"gen_version": WorldGenerator.GEN_VERSION}
	var grid := WorldGenerator.generate(31337, SIZE, reg)
	var s := WorldSession.from_grid(meta, grid)   # M1 had no NPCs
	var g := s.grid
	var cx := g.width / 2
	# 41 surface orders around the centre (one tile deep: always walkable).
	var shallow: Array[Vector2i] = []
	for x in range(cx - 20, cx + 21):
		var p := Vector2i(x, g.surface_y[x])
		assert_true(s.designations.designate(Rect2i(p, Vector2i.ONE), K.DIG).ok)
		shallow.append(p)
	# 120 orders buried deep in rock: no exposed face.
	assert_true(s.designations.designate(Rect2i(cx - 20, 60, 40, 3), K.DIG).ok)
	# An M1 dev edit (F9) so a modified chunk is stored.
	g.apply_edit(Rect2i(10, g.surface_y[10], 2, 2), WorldGrid.Edit.DIG)
	var orders := s.designations.count()
	assert_eq(orders, 41 + 120)
	assert_true(SaveService.write_atomic(dir.path_join("manual.save"), _v1_payload(s)).ok)

	var r := SaveService.load_world(dir, reg, meta)
	assert_true(r.ok, str(r))
	assert_eq(r.data["migrated_from"], 1)
	assert_eq(r.data["dropped"], {"designations": 0, "inventory": 0, "stockpiles": 0, "colony": 0, "jobs": 0})
	var l: WorldSession = r.data["session"]
	assert_eq(l.colony.count(), Colony.START_NPCS)
	assert_eq(l.designations.count(), orders)
	assert_eq(l.jobs.job_count(), orders, "every M1 order became exactly one job")
	assert_eq(l.grid.terrain_hash(), g.terrain_hash())
	for n in l.colony.all_npcs():
		assert_true(l.nav.can_stand(n.tile), "%s spawned on a standable tile" % n.id)

	var flagged := false
	var ever := {}
	var samples := 0
	var flagged_samples := 0
	var deep_held := 0
	for tick in range(1, 6001):
		l.clock.tick_index = tick
		l.simulate_tick(tick)
		if tick % 10 == 0:
			var errs := l.jobs.check_invariants()
			errs.append_array(l.inventory.check_conservation())
			errs.append_array(QA.extra_invariants(l))
			if not errs.is_empty():
				fail_test("tick %d: %s" % [tick, errs.slice(0, 5)])
				return
			var all := true
			for x in range(cx - 20, cx + 20):
				var p := Vector2i(x, 61)
				if l.jobs.is_unreachable(p):
					ever[p] = true
					flagged_samples += 1
				samples += 1
				all = all and ever.has(p)
			flagged = flagged or all
			for n in l.colony.all_npcs():
				var j := l.jobs.get_job(n.job_id)
				if j != null and j.tile.y >= 60:
					deep_held += 1
	var dug := 0
	for p in shallow:
		if l.grid.get_tile(p) == TileRegistry.AIR:
			dug += 1
	assert_eq(dug, shallow.size(), "all reachable M1 orders dug after migration")
	assert_true(flagged, "buried M1 orders are shown unreachable")
	gut.p("migration: buried orders flagged unreachable in %.0f%% of samples (overlay flicker)" % [
			100.0 * flagged_samples / maxi(1, samples)])
	assert_eq(deep_held, 0, "no NPC ever held a buried order")
	assert_eq(l.designations.count(), 120, "only the buried orders remain")
	assert_almost_eq(float(l.inventory.spawned_kg_by_material().get(&"dirt", 0.0)), shallow.size() * 50.0, 0.001,
			"one 50 kg drop per dug surface tile")
	# Re-save writes v2 and round-trips with no loss.
	assert_true(SaveService.save(l, dir, SaveService.Kind.AUTO).ok)
	var r2 := SaveService.load_world(dir, reg, meta)
	assert_true(r2.ok)
	var l2: WorldSession = r2.data["session"]
	assert_eq(r2.data["migrated_from"], 2)
	assert_eq(l2.inventory.to_snapshot()["items"], l.inventory.to_snapshot()["items"])
	assert_eq(l2.colony.count(), Colony.START_NPCS, "no second starting colony on re-load")
