class_name StableIdAllocator
extends RefCounted
## Allocates explicit, persistent IDs per entity category (spec §10).
## IDs have the form "<category>:<n>" with n starting at 1, are never reused,
## and the allocator state is saved so loaded games continue the sequence.
## Allocation is deterministic: it never uses randomness or time.

const SEPARATOR := ":"

var _next: Dictionary = {}  # StringName category -> int next value


func allocate(category: StringName) -> String:
	assert(not String(category).is_empty(), "category required")
	assert(not String(category).contains(SEPARATOR), "category must not contain ':'")
	var n: int = _next.get(category, 1)
	_next[category] = n + 1
	return "%s%s%d" % [category, SEPARATOR, n]


func peek_next(category: StringName) -> int:
	return _next.get(category, 1)


static func category_of(id: String) -> StringName:
	var idx := id.rfind(SEPARATOR)
	return StringName(id.substr(0, idx)) if idx > 0 else &""


static func is_valid(id: String) -> bool:
	var idx := id.rfind(SEPARATOR)
	if idx <= 0 or idx == id.length() - 1:
		return false
	var num := id.substr(idx + 1)
	return num.is_valid_int() and int(num) >= 1


func to_snapshot() -> Dictionary:
	var out := {}
	for k in _next:
		out[String(k)] = _next[k]
	return out


func load_snapshot(snapshot: Dictionary) -> void:
	_next.clear()
	for k in snapshot:
		_next[StringName(k)] = int(snapshot[k])
