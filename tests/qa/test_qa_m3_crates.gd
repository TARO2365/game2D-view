extends GutTest
## QA M3: crates — preference over zones, filters, capacity, never re-hauled,
## build material taken from crates; lead (a): a second crate order shown
## unreachable while the first is built.
## Grid 48x32: rows < 10 air, dirt below, bedrock bottom row (feet row 9).

const ENV := preload("res://tools/qa_m3_env.gd")
const K := DesignationMap.Kind

var reg: TileRegistry
var e: Variant


func before_all() -> void:
	reg = TileRegistry.load_default()


func before_each() -> void:
	e = ENV.new(reg)


func _ok_run(ticks: int, cond: Callable, msg: String) -> void:
	var ok: bool = e.run(ticks, cond)
	assert_eq(e.errors, [] as Array[String], "invariants")
	assert_true(ok, "%s; jobs: %s" % [msg, e.jobs_text()])


func _dev_crate(o: Vector2i) -> String:
	var r: CommandResult = e.ses.buildings.place(&"crate", o, {&"rock": 50.0})
	assert_true(r.ok, str(r))
	return r.data["id"]


# --- Lead (a) -----------------------------------------------------------------

## Two crate orders next to each other, material for both, one NPC. Whatever
## is shown, the second order must never be flagged unreachable while it is
## reachable, and both must get built.
func test_lead_a_second_crate_order_not_flagged_unreachable() -> void:
	var s: WorldSession = e.ses
	s.colony.spawn_npc(Vector2i(5, 9))
	s.inventory.spawn_ground(&"rock", 200.0, Vector2i(2, 9))
	assert_true(s.build_orders.order_building(&"crate", Vector2i(20, 9)).ok)
	assert_true(s.build_orders.order_building(&"crate", Vector2i(22, 9)).ok)
	var flagged := [0, -1]  # ticks flagged, first tick
	var ok: bool = e.run(4000, func() -> bool:
		for o in [Vector2i(20, 9), Vector2i(22, 9)]:
			if s.build_orders.order_at(o).is_empty():
				continue
			var j := _building_job_at(o)
			if j != null and s.jobs.is_unreachable(o) or (j != null and j.unreachable_until >= 0):
				flagged[0] += 1
				if flagged[1] < 0:
					flagged[1] = e.t
					gut.p("tick %d: order at %s flagged: %s" % [e.t, o, e.jobs_text()])
		return s.crates.crate_ids().size() == 2)
	assert_eq(e.errors, [] as Array[String])
	assert_true(ok, "both crates built; %s" % e.jobs_text())
	assert_eq(flagged[0], 0, "a reachable crate order was shown unreachable for %d ticks (first at %d)" % flagged)


## Lead (a), likely cause: the NPC has a recorded (confined) region — here
## forced by a sealed dig order whose search exhausts the small surface — and
## the only material went into the first crate. The second order is then
## missing MATERIAL, not reachability: it must say "no material" and must not
## be tinted unreachable.
## BUG M3-QA-4: confirmed failing without pending() on 2026-10-20: flagged
## unreachable for 2619 of 3000 ticks ("Build crate (22, 9) - unreachable",
## NPC region valid). _first_goals returns "no material in reach" for a
## confined NPC, try_assign treats it as a reach failure (_mark), and
## _sweep_unreachable then flags the job for everyone.
func test_lead_a_no_material_confined_npc_not_unreachable() -> void:
	pending("BUG M3-QA-4: 'no material' shown as unreachable when the NPC has a recorded region (lead a)")
	return
	@warning_ignore("unreachable_code")
	var s: WorldSession = e.ses
	var n := s.colony.spawn_npc(Vector2i(5, 9))
	s.grid.apply_edit(Rect2i(30, 20, 4, 3), WorldGrid.Edit.DIG)     # sealed pocket
	s.designations.designate(Rect2i(30, 19, 1, 1), K.DIG, 1)         # unreachable, forces a full search
	s.inventory.spawn_ground(&"rock", 50.0, Vector2i(2, 9))          # enough for ONE crate
	assert_true(s.build_orders.order_building(&"crate", Vector2i(20, 9)).ok)
	assert_true(s.build_orders.order_building(&"crate", Vector2i(22, 9)).ok)
	var flagged := [0, -1, ""]
	e.run(3000, func() -> bool:
		var j := _building_job_at(Vector2i(22, 9))
		if j == null:
			j = _building_job_at(Vector2i(20, 9)) if s.crates.crate_ids().size() == 1 else null
		if j != null and s.jobs.is_unreachable(j.tile):
			flagged[0] += 1
			if flagged[1] < 0:
				flagged[1] = e.t
				flagged[2] = "%s; npc region valid %s" % [e.jobs_text(), n._region_valid]
		return false)
	assert_eq(e.errors, [] as Array[String])
	assert_eq(s.crates.crate_ids().size(), 1, "one crate built (material for one)")
	gut.p("second crate order flagged unreachable for %d of 3000 ticks, first at %d: %s" % flagged)
	assert_eq(flagged[0], 0, "a crate order missing only material is shown unreachable (%d ticks, first %d: %s)" % flagged)


func _building_job_at(o: Vector2i) -> Job:
	for j in e.ses.jobs.all_jobs():
		if j.kind == Job.KIND_BUILDING and j.tile == o:
			return j
	return null


# --- Preference, filters, capacity -------------------------------------------

func test_crate_preferred_over_nearer_zone() -> void:
	var s: WorldSession = e.ses
	s.colony.spawn_npc(Vector2i(5, 9))
	s.stockpiles.designate(Rect2i(11, 9, 1, 1))          # 1 tile from the stack
	var cid := _dev_crate(Vector2i(30, 9))               # 20 tiles away
	s.inventory.spawn_ground(&"dirt", 60.0, Vector2i(10, 9))
	_ok_run(2000, func() -> bool: return s.inventory.crate_kg(cid) > 59.0, "stack stored in the far crate")
	assert_almost_eq(s.inventory.ground_kg_at(Vector2i(11, 9)), 0.0, 0.001, "zone not used")


func test_filter_and_capacity() -> void:
	var s: WorldSession = e.ses
	s.colony.spawn_npc(Vector2i(5, 9))
	s.colony.spawn_npc(Vector2i(8, 9))
	s.stockpiles.designate(Rect2i(36, 9, 6, 1))
	var rock_crate := _dev_crate(Vector2i(25, 9))
	var any_crate := _dev_crate(Vector2i(28, 9))
	assert_true(s.crates.set_filter(rock_crate, [&"rock"] as Array[StringName]).ok)
	for i in 14:
		s.inventory.spawn_ground(&"dirt", 200.0, Vector2i(2 + i % 6, 9))   # 2800 kg dirt
	s.inventory.spawn_ground(&"rock", 100.0, Vector2i(9, 9))
	_ok_run(20000, func() -> bool:
		for it in s.inventory.all_items():
			if it.holder != Inventory.Holder.CRATE and not s.stockpiles.is_stored(it):
				return false
		return true, "everything stored")
	for it in s.inventory.crate_items(rock_crate):
		assert_eq(it.material, &"rock", "filtered crate holds rock only")
	assert_almost_eq(s.inventory.crate_kg(rock_crate), 100.0, 0.001)
	assert_almost_eq(s.inventory.crate_kg(any_crate), 2000.0, 0.001, "open crate filled to capacity, never over")
	var zone_kg := 0.0
	for x in range(36, 42):
		zone_kg += s.inventory.ground_kg_at(Vector2i(x, 9))
	assert_almost_eq(zone_kg, 800.0, 0.001, "overflow went to the zone")


## The player changes a crate's filter while a hauler is carrying a now
## refused material to it: the stack must not end up in that crate.
## BUG M3-QA-3: confirmed failing without pending() on 2026-10-20: the 60 kg
## of dirt ends in the rock-only crate (_drive_haul stores into the booked
## crate without re-checking CrateStorage.accepts; set_filter keeps bookings).
func test_filter_changed_while_carrying() -> void:
	pending("BUG M3-QA-3: a stack booked before a filter change is still stored in the crate that now refuses it")
	return
	@warning_ignore("unreachable_code")
	var s: WorldSession = e.ses
	var n := s.colony.spawn_npc(Vector2i(5, 9))
	s.stockpiles.designate(Rect2i(40, 9, 2, 1))
	var cid := _dev_crate(Vector2i(30, 9))
	s.inventory.spawn_ground(&"dirt", 60.0, Vector2i(8, 9))
	_ok_run(1500, func() -> bool: return s.inventory.carried_by(n.id) != null, "carrying to the crate")
	assert_eq(s.crates.booked_crate(n.job_id), cid, "booked into the crate")
	assert_true(s.crates.set_filter(cid, [&"rock"] as Array[StringName]).ok)
	_ok_run(2000, func() -> bool: return s.inventory.carried_by(n.id) == null and n.job_id.is_empty(), "delivered")
	assert_almost_eq(s.inventory.crate_kg(cid), 0.0, 0.001, "dirt not put into a rock-only crate")


## Stored stacks are never hauled again (new nearer crate, zone removed,
## filter changed afterwards).
func test_crate_items_never_rehauled() -> void:
	var s: WorldSession = e.ses
	var n := s.colony.spawn_npc(Vector2i(5, 9))
	var far := _dev_crate(Vector2i(35, 9))
	s.inventory.spawn_ground(&"dirt", 150.0, Vector2i(8, 9))
	_ok_run(2000, func() -> bool: return s.inventory.crate_kg(far) > 149.0, "stored")
	var moves := [0]
	s.inventory.items_changed.connect(func(_iid: String) -> void: moves[0] += 1)
	_dev_crate(Vector2i(9, 9))
	s.stockpiles.designate(Rect2i(10, 9, 3, 1))
	s.crates.set_filter(far, [&"rock"] as Array[StringName])
	e.run(1500)
	assert_eq(e.errors, [] as Array[String])
	assert_eq(moves[0], 0, "no stack moved out of the crate")
	assert_almost_eq(s.inventory.crate_kg(far), 150.0, 0.001)
	assert_eq(n.job_id, "")


func test_build_material_from_crate_exact() -> void:
	var s: WorldSession = e.ses
	s.colony.spawn_npc(Vector2i(5, 9))
	var cid := _dev_crate(Vector2i(10, 9))
	e.fill_crate(cid, &"rock", 130.0)
	assert_true(s.build_orders.order_building(&"table", Vector2i(20, 9)).ok)
	assert_true(s.build_orders.order_building(&"door", Vector2i(30, 9)).code == &"no_support")
	_ok_run(3000, func() -> bool: return s.buildings.count() == 2, "table built from crate rock")
	assert_almost_eq(s.inventory.crate_kg(cid), 80.0, 0.001, "exactly 50 kg taken")
	for it in s.inventory.all_items():
		assert_eq(it.holder, Inventory.Holder.CRATE, "the rest stays in the crate: %s" % it.id)


## Crate deconstructed while a builder walks to fetch a stack from it.
func test_crate_deconstructed_while_material_reserved() -> void:
	var s: WorldSession = e.ses
	var builder := s.colony.spawn_npc(Vector2i(40, 9))
	var cid := _dev_crate(Vector2i(10, 9))
	e.fill_crate(cid, &"rock", 100.0)
	assert_true(s.build_orders.order_building(&"table", Vector2i(42, 9)).ok)
	_ok_run(500, func() -> bool:
		var j := s.jobs.get_job(builder.job_id)
		return j != null and not j.item_id.is_empty() and builder.is_moving(), "builder walking to the crate")
	var reserved: String = s.jobs.get_job(builder.job_id).item_id
	assert_eq(s.inventory.get_item(reserved).holder, Inventory.Holder.CRATE, "reserved stack is in the crate")
	# A second NPC next to the crate deconstructs it before the builder arrives.
	s.colony.spawn_npc(Vector2i(11, 9))
	assert_true(s.designations.designate(Rect2i(10, 9, 1, 1), K.DECONSTRUCT, 9).ok)
	_ok_run(6000, func() -> bool: return s.buildings.count() == 1 and s.crates.crate_ids().is_empty(),
			"crate deconstructed and the table still built")
	assert_almost_eq(e.kg(&"rock"), 100.0 + 50.0 - 50.0, 0.001, "contents + refund - table")
