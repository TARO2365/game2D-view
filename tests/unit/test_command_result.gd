extends GutTest


func test_success_carries_payload() -> void:
	var r := CommandResult.success({"id": "npc:1"})
	assert_true(r.ok)
	assert_eq(r.code, &"")
	assert_eq(r.data["id"], "npc:1")


func test_failure_carries_code_and_message() -> void:
	var r := CommandResult.failure(&"blocked", "Tile is occupied")
	assert_false(r.ok)
	assert_eq(r.code, &"blocked")
	assert_eq(r.message, "Tile is occupied")
	assert_string_contains(str(r), "blocked")
