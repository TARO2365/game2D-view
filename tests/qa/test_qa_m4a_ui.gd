extends GutTest
## QA M4a UI / art checks that can run headless: no magenta fallback for
## any material a stack can have (incl. food), lying poses for sleeping /
## collapsed NPCs, farm plot / kitchen drawn by their own art branch, and the
## alerts panel after loading a paused game.

const ENV := preload("res://tools/qa_m3_env.gd")

var reg: TileRegistry


func before_all() -> void:
	reg = TileRegistry.load_default()


## BUG M4A-QA-4 (fixed by the Asset Agent 2026-10-22; was confirmed failing): ration,
## meal and mushroom stacks draw in Color.MAGENTA (ItemView only knows tile
## materials) — seen on Web: the starting ration is a magenta chunk.
func test_food_items_have_art_not_magenta() -> void:
	var mats := MaterialDefs.load_default()
	var ids := StableIdAllocator.new()
	var v := ItemView.new()
	v.setup(Inventory.new(ids), reg, 64)
	var bad: Array[String] = []
	for m in mats.all_keys():
		var has_icon: bool = v._icons.get(m) != null
		var col: Color = v._colors.get(m, Color.MAGENTA)
		if not has_icon and col == Color.MAGENTA:
			bad.append("ground %s" % m)
		if NpcView.material_art_color(reg, m) == Color.MAGENTA:
			bad.append("carried %s" % m)
	v.free()
	assert_eq(bad, [] as Array[String], "every material has art or a colour")


func test_sleeping_and_collapsed_npcs_lie_down() -> void:
	assert_eq(NpcView.anim_for(&"sleeping", false, false, false), &"sleep")
	assert_eq(NpcView.anim_for(&"collapsed", false, false, false), &"sleep")
	assert_eq(NpcView.anim_for(&"collapsed", true, false, true), &"sleep", "collapsed overrides moving/carrying")
	assert_eq(NpcView.anim_for(&"eating", false, false, true), &"eat")


## Farm plot and kitchen placeholder art: checked by code review only
## (BuildingView.draw_art has their own branches; magenta is the fallback) and
## visually NOT RUN (no farm/kitchen on the Web run).


## Alerts are re-raised by their producers on simulation ticks. A game saved
## while paused loads with an EMPTY alerts panel until the clock runs.
## BUG M4A-QA-6: confirmed failing without pending() on 2026-10-22 (also on
## Web: "No alerts" after restart+load of a paused game that had 4 alerts).
func test_alerts_present_right_after_loading_a_paused_game() -> void:
	var e: Variant = ENV.new(reg)
	var a: Npc = e.ses.colony.spawn_npc(Vector2i(10, 9))
	a.hunger = 0.0
	a.health = 0.5
	e.run(60)
	var before: Array = e.ses.alerts.alerts().map(func(x: Dictionary) -> String: return x["key"])
	assert_gt(before.size(), 0)
	assert_eq(e.reload(), [] as Array[String])
	var after: Array = e.ses.alerts.alerts().map(func(x: Dictionary) -> String: return x["key"])
	assert_eq(after, before, "alerts shown straight after load, before any tick")
