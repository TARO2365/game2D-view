extends Node
## M0 bootstrap scene: owns the SimulationClock and wires the minimal UI shell.
## Real subsystems (World, Navigation, ...) attach here from M1 onward.

const SCALE_CONFIG_PATH := "res://data/config/scale_config.tres"

var clock := SimulationClock.new()
var ids := StableIdAllocator.new()
var scale_config: ScaleConfig

@onready var _speed_bar: SpeedBar = $UI/SpeedBar


func _ready() -> void:
	scale_config = load(SCALE_CONFIG_PATH) as ScaleConfig
	_speed_bar.bind_clock(clock)


func _process(delta: float) -> void:
	clock.advance(delta)
