class_name SimulationClock
extends RefCounted
## Fixed-step simulation clock (spec §2). Owns tick index and game speed only.
## Rendering FPS is decoupled: callers feed real frame delta into advance(),
## and the clock emits zero or more fixed ticks.
##
## NOTE: TICK_RATE_HZ and cadence intervals are PLACEHOLDERS (spec §17: TBD by
## profiling). Changing them is a DECISIONS.md entry, not a silent tweak.

signal ticked(tick_index: int)
signal speed_changed(new_speed: int)

enum Cadence { FAST, NORMAL, SLOW }

const ALLOWED_SPEEDS: Array[int] = [0, 1, 2, 3]  # 0 = Pause
const TICK_RATE_HZ := 10.0  # PLACEHOLDER
## Guard against the "spiral of death" when a frame stalls.
const MAX_TICKS_PER_ADVANCE := 12  # PLACEHOLDER
## Every N ticks a subsystem of the given cadence runs. PLACEHOLDER.
const CADENCE_INTERVAL := {
	Cadence.FAST: 1,
	Cadence.NORMAL: 5,
	Cadence.SLOW: 20,
}

var tick_index: int = 0
var speed: int = 1
## Real seconds of simulation time discarded by the per-advance cap.
var dropped_seconds: float = 0.0

var _accumulator: float = 0.0


func set_speed(new_speed: int) -> CommandResult:
	if new_speed not in ALLOWED_SPEEDS:
		return CommandResult.failure(&"invalid_speed",
				"Speed must be one of %s" % [ALLOWED_SPEEDS], {"requested": new_speed})
	if new_speed != speed:
		speed = new_speed
		speed_changed.emit(speed)
	return CommandResult.success({"speed": speed})


func is_paused() -> bool:
	return speed == 0


func tick_seconds() -> float:
	return 1.0 / TICK_RATE_HZ


## Feed real elapsed seconds. Returns number of ticks executed.
func advance(real_delta: float) -> int:
	if speed == 0 or real_delta <= 0.0:
		return 0
	_accumulator += real_delta * speed
	var step := tick_seconds()
	var count := 0
	while _accumulator >= step and count < MAX_TICKS_PER_ADVANCE:
		_accumulator -= step
		tick_index += 1
		count += 1
		ticked.emit(tick_index)
	if _accumulator >= step:
		# Budget exceeded: drop backlog rather than freeze the frame.
		dropped_seconds += _accumulator
		_accumulator = 0.0
	return count


static func is_cadence_due(cadence: Cadence, at_tick: int) -> bool:
	return at_tick % int(CADENCE_INTERVAL[cadence]) == 0


func to_snapshot() -> Dictionary:
	return {"tick_index": tick_index, "speed": speed}


func load_snapshot(snapshot: Dictionary) -> void:
	tick_index = int(snapshot.get("tick_index", 0))
	var s := int(snapshot.get("speed", 1))
	speed = s if s in ALLOWED_SPEEDS else 1
	_accumulator = 0.0
