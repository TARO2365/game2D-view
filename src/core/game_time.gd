class_name GameTime
extends RefCounted
## Time of day derived from SimulationClock.tick_index (never saved on its
## own). 1 day = 10 real minutes at 1x (D-028, P-4). PLACEHOLDER rates.

const TICKS_PER_DAY := 6000
const TICKS_PER_HOUR := 250
const NIGHT_START_HOUR := 20
const NIGHT_END_HOUR := 6


## 1-based day number.
static func day(tick: int) -> int:
	return tick / TICKS_PER_DAY + 1


static func hour(tick: int) -> int:
	return (tick % TICKS_PER_DAY) / TICKS_PER_HOUR


static func minute(tick: int) -> int:
	return (tick % TICKS_PER_HOUR) * 60 / TICKS_PER_HOUR


## Visual only in M4a.
static func is_night(tick: int) -> bool:
	var h := hour(tick)
	return h >= NIGHT_START_HOUR or h < NIGHT_END_HOUR


static func label(tick: int) -> String:
	return "Day %d  %02d:%02d" % [day(tick), hour(tick), minute(tick)]
