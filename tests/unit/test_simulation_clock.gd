extends GutTest

var clock: SimulationClock


func before_each() -> void:
	clock = SimulationClock.new()


func test_defaults() -> void:
	assert_eq(clock.speed, 1)
	assert_eq(clock.tick_index, 0)


func test_one_second_at_1x_gives_tick_rate_ticks() -> void:
	var n := 0
	for i in 10:
		n += clock.advance(0.1)
	assert_eq(n, int(SimulationClock.TICK_RATE_HZ))
	assert_eq(clock.tick_index, n)


func test_speed_multiplies_ticks() -> void:
	clock.set_speed(3)
	var n := 0
	for i in 10:
		n += clock.advance(0.1)
	assert_eq(n, int(SimulationClock.TICK_RATE_HZ) * 3)


func test_pause_produces_no_ticks() -> void:
	assert_true(clock.set_speed(0).ok)
	assert_true(clock.is_paused())
	assert_eq(clock.advance(5.0), 0)
	assert_eq(clock.tick_index, 0)


func test_invalid_speed_rejected_and_state_unchanged() -> void:
	clock.set_speed(2)
	var r := clock.set_speed(7)
	assert_false(r.ok)
	assert_eq(r.code, &"invalid_speed")
	assert_eq(clock.speed, 2)


func test_speed_changed_signal_only_on_change() -> void:
	watch_signals(clock)
	clock.set_speed(1)
	assert_signal_not_emitted(clock, "speed_changed")
	clock.set_speed(2)
	assert_signal_emitted_with_parameters(clock, "speed_changed", [2])


func test_ticked_signal_emits_each_tick() -> void:
	watch_signals(clock)
	clock.advance(0.35)
	assert_signal_emit_count(clock, "ticked", 3)


func test_long_stall_is_capped_and_recorded() -> void:
	var n := clock.advance(100.0)
	assert_eq(n, SimulationClock.MAX_TICKS_PER_ADVANCE)
	assert_gt(clock.dropped_seconds, 0.0)
	# Backlog does not carry over into the next frame.
	assert_eq(clock.advance(0.0), 0)


func test_cadence_intervals() -> void:
	assert_true(SimulationClock.is_cadence_due(SimulationClock.Cadence.FAST, 7))
	assert_true(SimulationClock.is_cadence_due(SimulationClock.Cadence.NORMAL, 10))
	assert_false(SimulationClock.is_cadence_due(SimulationClock.Cadence.NORMAL, 11))
	assert_true(SimulationClock.is_cadence_due(SimulationClock.Cadence.SLOW, 40))
	assert_false(SimulationClock.is_cadence_due(SimulationClock.Cadence.SLOW, 30))


func test_tick_count_is_deterministic_for_same_input() -> void:
	var deltas := [0.016, 0.033, 0.1, 0.007, 0.25, 0.016, 0.5]
	var a := SimulationClock.new()
	var b := SimulationClock.new()
	for d in deltas:
		a.advance(d)
		b.advance(d)
	assert_eq(a.tick_index, b.tick_index)


func test_snapshot_round_trip() -> void:
	clock.set_speed(2)
	clock.advance(1.0)
	var snap := clock.to_snapshot()
	var c2 := SimulationClock.new()
	c2.load_snapshot(JSON.parse_string(JSON.stringify(snap)))
	assert_eq(c2.tick_index, clock.tick_index)
	assert_eq(c2.speed, 2)


func test_snapshot_with_bad_speed_falls_back() -> void:
	var c2 := SimulationClock.new()
	c2.load_snapshot({"tick_index": 5, "speed": 99})
	assert_eq(c2.speed, 1)
	assert_eq(c2.tick_index, 5)
