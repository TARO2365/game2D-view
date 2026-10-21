class_name AlertService
extends RefCounted
## Colony alerts (spec §9): general / important / emergency. Producers own
## their keys (e.g. "npc:3/hungry") and set or clear them every time state
## changes; alerts are derived state and are NOT saved — producers re-raise
## them after load.

signal alerts_changed

enum Severity { GENERAL = 0, IMPORTANT = 1, EMERGENCY = 2 }

const NO_TILE := Vector2i(-1, -1)

## Tick used for `since_tick` of new alerts (set by the session each tick).
var current_tick := 0

var _alerts: Dictionary = {}  # key -> Dictionary


func set_alert(key: String, severity: Severity, message: String,
		tile: Vector2i = NO_TILE, npc_id: String = "") -> void:
	var old: Dictionary = _alerts.get(key, {})
	if not old.is_empty() and old["severity"] == severity and old["message"] == message \
			and old["tile"] == tile and old["npc_id"] == npc_id:
		return  # unchanged: keep since_tick, no signal
	_alerts[key] = {"key": key, "severity": severity, "message": message, "tile": tile,
			"npc_id": npc_id, "since_tick": old.get("since_tick", current_tick)}
	alerts_changed.emit()


func clear(key: String) -> void:
	if _alerts.erase(key):
		alerts_changed.emit()


func clear_prefix(prefix: String) -> void:
	var removed := false
	for k in _alerts.keys():
		if String(k).begins_with(prefix):
			_alerts.erase(k)
			removed = true
	if removed:
		alerts_changed.emit()


func has_alert(key: String) -> bool:
	return _alerts.has(key)


func count() -> int:
	return _alerts.size()


## Sorted: severity (highest first), then key.
func alerts() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for k in _alerts:
		out.append(_alerts[k].duplicate())
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["severity"] != b["severity"]:
			return a["severity"] > b["severity"]
		return String(a["key"]) < String(b["key"]))
	return out
