class_name UiStyle
extends RefCounted
## Shared placeholder UI styling: panel background, need bars, colours.
## PLACEHOLDER values until the UX/art pass.

const PANEL_COLOR := Color(0.11, 0.1, 0.12, 0.96)
const PANEL_BORDER := Color(0.45, 0.4, 0.3)
const TOUCH := 44.0
const HUNGER_COLOR := Color(0.95, 0.65, 0.2)
const STAMINA_COLOR := Color(0.4, 0.65, 1.0)
const HEALTH_COLOR := Color(0.9, 0.3, 0.3)
const BAR_BG := Color(0, 0, 0, 0.55)
const SEVERITY_COLORS := {0: Color(0.7, 0.7, 0.72), 1: Color(1.0, 0.62, 0.2), 2: Color(1.0, 0.3, 0.28)}
const CONDITION_NAMES := {&"ok": "OK", &"collapsed": "Collapsed", &"dead": "Dead"}


static func panel_box() -> StyleBoxFlat:
	var bg := StyleBoxFlat.new()
	bg.bg_color = PANEL_COLOR
	bg.border_color = PANEL_BORDER
	bg.set_border_width_all(2)
	bg.set_corner_radius_all(4)
	bg.set_content_margin_all(10)
	return bg


## Thin coloured 0..100 bar (no percentage text).
static func need_bar(color: Color, height: float = 12.0) -> ProgressBar:
	var b := ProgressBar.new()
	b.min_value = 0.0
	b.max_value = 100.0
	b.show_percentage = false
	b.custom_minimum_size = Vector2(0, height)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var bg := StyleBoxFlat.new()
	bg.bg_color = BAR_BG
	var fg := StyleBoxFlat.new()
	fg.bg_color = color
	b.add_theme_stylebox_override("background", bg)
	b.add_theme_stylebox_override("fill", fg)
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return b


static func condition_name(c: StringName) -> String:
	return CONDITION_NAMES.get(c, String(c).capitalize())


static func severity_color(s: int) -> Color:
	return SEVERITY_COLORS.get(s, SEVERITY_COLORS[0])
