class_name CommandResult
extends RefCounted
## Uniform result returned by every player/system command.
## Spec §10: "Every command validates prerequisites and returns a clear
## success/failure result." UI widgets must inspect this, never assume success.

var ok: bool = false
## Machine-readable failure code, e.g. &"invalid_speed". Empty on success.
var code: StringName = &""
## Human-readable explanation (may be shown to the player).
var message: String = ""
## Optional payload (e.g. created entity id).
var data: Dictionary = {}


static func success(payload: Dictionary = {}) -> CommandResult:
	var r := CommandResult.new()
	r.ok = true
	r.data = payload
	return r


static func failure(fail_code: StringName, msg: String, payload: Dictionary = {}) -> CommandResult:
	var r := CommandResult.new()
	r.ok = false
	r.code = fail_code
	r.message = msg
	r.data = payload
	return r


func _to_string() -> String:
	if ok:
		return "CommandResult(ok)"
	return "CommandResult(fail %s: %s)" % [code, message]
