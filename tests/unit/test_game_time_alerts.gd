extends GutTest


func test_time_of_day() -> void:
	assert_eq(GameTime.day(0), 1)
	assert_eq(GameTime.hour(0), 0)
	assert_eq(GameTime.day(GameTime.TICKS_PER_DAY), 2)
	var t := GameTime.TICKS_PER_DAY * 2 + 14 * GameTime.TICKS_PER_HOUR + GameTime.TICKS_PER_HOUR / 3
	assert_eq(GameTime.day(t), 3)
	assert_eq(GameTime.hour(t), 14)
	assert_eq(GameTime.minute(t), 19)  # 83/250 of an hour, floored
	assert_eq(GameTime.label(t), "Day 3  14:19")
	assert_true(GameTime.is_night(22 * GameTime.TICKS_PER_HOUR))
	assert_true(GameTime.is_night(3 * GameTime.TICKS_PER_HOUR))
	assert_false(GameTime.is_night(12 * GameTime.TICKS_PER_HOUR))
	assert_eq(GameTime.TICKS_PER_HOUR * 24, GameTime.TICKS_PER_DAY)


func test_alerts_sorted_dedup_and_cleared() -> void:
	var a := AlertService.new()
	watch_signals(a)
	a.current_tick = 10
	a.set_alert("npc:2/hungry", AlertService.Severity.IMPORTANT, "Hungry")
	a.set_alert("colony/no_food", AlertService.Severity.EMERGENCY, "No food left")
	a.set_alert("npc:1/tired", AlertService.Severity.GENERAL, "Tired")
	assert_signal_emit_count(a, "alerts_changed", 3)
	a.current_tick = 50
	a.set_alert("npc:2/hungry", AlertService.Severity.IMPORTANT, "Hungry")  # unchanged
	assert_signal_emit_count(a, "alerts_changed", 3, "no signal for an unchanged alert")
	var keys := a.alerts().map(func(x: Dictionary) -> String: return x["key"])
	assert_eq(keys, ["colony/no_food", "npc:2/hungry", "npc:1/tired"])
	a.set_alert("npc:2/hungry", AlertService.Severity.EMERGENCY, "Starving")
	assert_eq(a.alerts()[1]["since_tick"], 10, "escalation keeps the original start")
	a.clear_prefix("npc:")
	assert_eq(a.count(), 1)
	a.clear("colony/no_food")
	assert_eq(a.count(), 0)
	a.clear("missing")  # no-op
