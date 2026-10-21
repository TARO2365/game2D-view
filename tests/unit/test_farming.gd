extends GutTest
## Farming (M4a contract §5) with a fake Buildings provider.

const FB := preload("res://tests/helpers/fake_buildings.gd")
const S := Farming.Stage

var bld: RefCounted
var inv: Inventory
var farm: Farming


func before_each() -> void:
	bld = FB.new()
	inv = Inventory.new(StableIdAllocator.new())
	farm = Farming.new(bld, inv, StableIdAllocator.new())


func _grow(from_tick: int, ticks: int) -> int:
	for i in ticks:
		farm.update(from_tick + i)
	return from_tick + ticks


func test_farms_follow_farm_plot_buildings() -> void:
	watch_signals(farm)
	var a: String = bld.place(&"farm_plot", Vector2i(3, 9))
	bld.place(&"kitchen", Vector2i(6, 9))
	var c: String = bld.place(&"farm_plot", Vector2i(9, 9))
	assert_eq(farm.farm_ids(), [a, c] as Array[String])
	assert_true(farm.is_farm(a))
	assert_false(farm.is_farm("bld:2"), "kitchen")
	assert_eq(farm.stage(a), S.EMPTY)
	assert_eq(farm.stage("bld:2"), Farming.NO_FARM)
	assert_eq(farm.stage("bld:99"), Farming.NO_FARM)
	assert_eq(farm.progress(a), 0.0)
	assert_signal_emit_count(farm, "farms_changed", 2)


func test_grow_cycle() -> void:
	var a: String = bld.place(&"farm_plot", Vector2i(3, 9))
	watch_signals(farm)
	var r := farm.plant(a)
	assert_true(r.ok, str(r))
	assert_eq(farm.stage(a), S.GROWING)
	assert_eq(farm.plant(a).code, &"not_empty")
	assert_eq(farm.harvest(a, Vector2i(3, 9)).code, &"not_ready")
	var t := _grow(1, Farming.GROW_TICKS / 2)
	assert_almost_eq(farm.progress(a), 0.5, 0.001)
	assert_eq(farm.stage(a), S.GROWING)
	t = _grow(t, Farming.GROW_TICKS / 2 - 1)
	assert_eq(farm.stage(a), S.GROWING, "one tick short")
	_grow(t, 1)
	assert_eq(farm.stage(a), S.READY)
	assert_eq(farm.progress(a), 1.0)
	assert_signal_emit_count(farm, "farms_changed", 2, "plant + ready, not per growth tick")
	var h := farm.harvest(a, Vector2i(4, 9))
	assert_true(h.ok, str(h))
	var it := inv.get_item(h.data["item_id"])
	assert_eq(it.material, &"mushroom")
	assert_eq(it.kg, Farming.YIELD_KG)
	assert_eq(it.tile, Vector2i(4, 9))
	assert_eq(farm.stage(a), S.EMPTY)
	assert_eq(farm.progress(a), 0.0)
	assert_eq(inv.check_conservation(), [] as Array[String])
	assert_eq(inv.verify_indexes(), [] as Array[String])
	assert_true(farm.plant(a).ok, "can replant")


func test_update_uses_tick_delta() -> void:
	var a: String = bld.place(&"farm_plot", Vector2i(3, 9))
	farm.plant(a)
	farm.update(100)   # first call grows 1 tick
	farm.update(100)   # same tick: nothing
	farm.update(50)    # backwards: nothing
	assert_almost_eq(farm.progress(a), 1.0 / Farming.GROW_TICKS, 1e-9)
	farm.update(50 + 299)
	assert_almost_eq(farm.progress(a), 300.0 / Farming.GROW_TICKS, 1e-9)
	farm.update(999999)  # big jump is capped at GROW_TICKS
	assert_eq(farm.stage(a), S.READY)


func test_failures_on_non_farms() -> void:
	var k: String = bld.place(&"kitchen", Vector2i(6, 9))
	assert_eq(farm.plant(k).code, &"not_farm")
	assert_eq(farm.plant("bld:99").code, &"not_farm")
	assert_eq(farm.harvest(k, Vector2i.ZERO).code, &"not_farm")
	var a: String = bld.place(&"farm_plot", Vector2i(3, 9))
	assert_eq(farm.harvest(a, Vector2i.ZERO).code, &"not_ready", "empty farm")
	assert_eq(inv.all_items().size(), 0)


func test_removed_or_lost_farm_drops_crop() -> void:
	var a: String = bld.place(&"farm_plot", Vector2i(3, 9))
	var b: String = bld.place(&"farm_plot", Vector2i(6, 9))
	farm.plant(a)
	farm.plant(b)
	watch_signals(farm)
	bld.remove(a)
	assert_eq(farm.stage(a), Farming.NO_FARM)
	assert_signal_emitted_with_parameters(farm, "farms_changed", [a])
	bld.lose(b)
	assert_eq(farm.stage(b), Farming.NO_FARM)
	assert_signal_emit_count(farm, "farms_changed", 2, "a lost farm is reported once")
	assert_eq(farm.to_snapshot(), {"farms": []})
	# A new farm with a fresh id starts empty.
	var c: String = bld.place(&"farm_plot", Vector2i(3, 9))
	assert_eq(farm.stage(c), S.EMPTY)


func test_snapshot_round_trip() -> void:
	var a: String = bld.place(&"farm_plot", Vector2i(3, 9))
	var b: String = bld.place(&"farm_plot", Vector2i(6, 9))
	bld.place(&"farm_plot", Vector2i(9, 9))   # stays EMPTY: not listed
	farm.plant(a)
	_grow(1, 1234)
	farm.plant(b)
	var t := _grow(1235, Farming.GROW_TICKS - 1)
	assert_eq(farm.stage(a), S.READY)
	assert_eq(farm.stage(b), S.GROWING)
	var snap := farm.to_snapshot()
	assert_eq(snap, {"farms": [
		{"building_id": a, "stage": S.READY, "growth": Farming.GROW_TICKS},
		{"building_id": b, "stage": S.GROWING, "growth": Farming.GROW_TICKS - 1},
	]})
	var bytes := var_to_bytes(snap)
	var f2 := Farming.new(bld, inv)
	watch_signals(f2)
	assert_eq(f2.load_snapshot(bytes_to_var(bytes)), 0)
	assert_signal_emitted_with_parameters(f2, "farms_changed", [""])
	assert_eq(var_to_bytes(f2.to_snapshot()), bytes, "byte-identical re-save")
	assert_eq(f2.stage(b), S.GROWING)
	f2.update(t)
	assert_eq(f2.stage(b), S.READY, "growth continues after load")


func test_load_sanitizes_junk() -> void:
	var a: String = bld.place(&"farm_plot", Vector2i(3, 9))
	var b: String = bld.place(&"farm_plot", Vector2i(6, 9))
	var k: String = bld.place(&"kitchen", Vector2i(9, 9))
	var junk := {"farms": [
		{"building_id": a, "stage": S.GROWING, "growth": 100},
		{"building_id": a, "stage": S.READY, "growth": 0},              # duplicate
		{"building_id": k, "stage": S.GROWING, "growth": 1},            # not a farm
		{"building_id": "bld:99", "stage": S.GROWING, "growth": 1},     # unknown
		{"building_id": b, "stage": S.EMPTY, "growth": 0},              # empty is never saved
		{"building_id": b, "stage": 7, "growth": 0},
		{"building_id": b, "stage": S.GROWING, "growth": -1},
		{"building_id": b, "stage": S.GROWING, "growth": Farming.GROW_TICKS + 1},
		{"building_id": b, "stage": S.GROWING, "growth": 5.5},
		{"building_id": b, "stage": "1", "growth": 5},
		{"stage": S.GROWING, "growth": 5},
		"garbage",
		null,
	]}
	assert_eq(farm.load_snapshot(junk), 12)
	assert_eq(farm.stage(a), S.GROWING)
	assert_almost_eq(farm.progress(a), 100.0 / Farming.GROW_TICKS, 1e-9)
	assert_eq(farm.stage(b), S.EMPTY)
	assert_eq(farm.load_snapshot({"farms": [{"building_id": b, "stage": S.GROWING,
			"growth": Farming.GROW_TICKS}]}), 0)
	assert_eq(farm.stage(b), S.READY, "fully grown GROWING loads as READY")
	assert_eq(farm.load_snapshot({}), 0)
	assert_eq(farm.load_snapshot({"farms": "x"}), 0)
	assert_eq(farm.stage(b), S.EMPTY)


func test_silent_buildings_load_is_followed() -> void:
	var a: String = bld.place(&"farm_plot", Vector2i(3, 9))
	farm.plant(a)
	# Different building count -> the tracker notices without a signal.
	bld.load_silently({
		"bld:5": {"id": "bld:5", "key": &"farm_plot", "origin": Vector2i(1, 9), "materials": {}},
		"bld:6": {"id": "bld:6", "key": &"bed", "origin": Vector2i(4, 9), "materials": {}},
	})
	assert_eq(farm.farm_ids(), ["bld:5"] as Array[String])
	assert_eq(farm.stage(a), Farming.NO_FARM)
	farm.update(1)
	assert_eq(farm.to_snapshot(), {"farms": []}, "stale crop dropped")
