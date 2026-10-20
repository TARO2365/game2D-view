extends GutTest

const FS := preload("res://tests/helpers/fs_util.gd")

var reg: TileRegistry
var g: WorldGrid
var d: DesignationMap


func before_all() -> void:
	reg = TileRegistry.load_default()


func before_each() -> void:
	g = FS.make_grid(reg)
	d = DesignationMap.new(g)


func test_dig_order_does_not_touch_terrain() -> void:
	var before := g.world_hash()
	var r := d.designate(Rect2i(0, 8, 4, 4), DesignationMap.Kind.DIG)
	assert_true(r.ok, str(r))
	assert_eq(r.data["added"], 8, "only the dirt rows")
	assert_eq(d.count(), 8)
	assert_eq(d.get_kind(Vector2i(0, 10)), DesignationMap.Kind.DIG)
	assert_eq(d.get_kind(Vector2i(0, 8)), DesignationMap.Kind.NONE)
	assert_eq(g.world_hash(), before, "D-015: orders never edit terrain")


func test_invalid_orders_rejected() -> void:
	assert_eq(d.designate(Rect2i(0, 0, 4, 4), DesignationMap.Kind.DIG).code, &"nothing_to_designate")
	assert_eq(d.designate(Rect2i(0, 20, 4, 4), DesignationMap.Kind.BUILD_WALL).code, &"nothing_to_designate")
	assert_eq(d.designate(Rect2i(0, 63, 4, 1), DesignationMap.Kind.DIG).code, &"nothing_to_designate", "bedrock")
	assert_eq(d.designate(Rect2i(-9, -9, 2, 2), DesignationMap.Kind.DIG).code, &"out_of_bounds")
	assert_eq(d.designate(Rect2i(0, 20, 1, 1), DesignationMap.Kind.NONE).code, &"invalid_kind")
	assert_eq(d.count(), 0)


func test_repeat_designation_is_noop() -> void:
	d.designate(Rect2i(0, 20, 2, 2), DesignationMap.Kind.DIG)
	var r := d.designate(Rect2i(0, 20, 2, 2), DesignationMap.Kind.DIG)
	assert_false(r.ok)
	assert_eq(d.count(), 4)


func test_build_and_cancel() -> void:
	watch_signals(d)
	assert_true(d.designate(Rect2i(0, 0, 3, 3), DesignationMap.Kind.BUILD_WALL).ok)
	assert_eq(d.count(), 9)
	var c := d.cancel(Rect2i(0, 0, 2, 3))
	assert_true(c.ok)
	assert_eq(c.data["removed"], 6)
	assert_eq(d.count(), 3)
	assert_eq(d.cancel(Rect2i(30, 30, 2, 2)).code, &"nothing_to_cancel")
	assert_signal_emit_count(d, "designations_changed", 2)


func test_terrain_change_removes_stale_orders() -> void:
	d.designate(Rect2i(0, 20, 3, 1), DesignationMap.Kind.DIG)
	d.designate(Rect2i(0, 0, 2, 1), DesignationMap.Kind.BUILD_WALL)
	watch_signals(d)
	g.apply_edit(Rect2i(0, 20, 2, 1), WorldGrid.Edit.DIG)
	assert_eq(d.get_kind(Vector2i(0, 20)), DesignationMap.Kind.NONE, "dug tile no longer needs a dig order")
	assert_eq(d.get_kind(Vector2i(2, 20)), DesignationMap.Kind.DIG)
	assert_signal_emitted(d, "designations_changed")
	g.apply_edit(Rect2i(0, 0, 1, 1), WorldGrid.Edit.BUILD_WALL)
	assert_eq(d.get_kind(Vector2i(0, 0)), DesignationMap.Kind.NONE)
	assert_eq(d.count(), 2)


func test_snapshot_round_trip_and_sanitising() -> void:
	d.designate(Rect2i(5, 20, 3, 2), DesignationMap.Kind.DIG)
	d.designate(Rect2i(5, 0, 2, 2), DesignationMap.Kind.BUILD_WALL)
	var snap: Dictionary = bytes_to_var(var_to_bytes(d.to_snapshot()))
	var d2 := DesignationMap.new(FS.make_grid(reg))
	assert_eq(d2.load_snapshot(snap), 0)
	assert_eq(d2.to_snapshot(), d.to_snapshot())
	var bad := {"indices": PackedInt32Array([-1, 999999, 10 * 64 + 1, 0]),
			"kinds": PackedByteArray([1, 1, 7, 1])}
	var d3 := DesignationMap.new(FS.make_grid(reg))
	assert_eq(d3.load_snapshot(bad), 4, "out of range, invalid kind, dig on air all dropped")
	assert_eq(d3.count(), 0)
	assert_eq(d3.load_snapshot({"indices": "junk"}), 0)
