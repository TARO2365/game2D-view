class_name ClockView
extends HBoxContainer
## HUD clock: sun/moon glyph + "Day N  hh:mm" from GameTime (read-only).

const ICON_SIZE := Vector2(28, 28)
const SUN := Color(1.0, 0.82, 0.3)
const MOON := Color(0.8, 0.85, 1.0)

var clock: SimulationClock
var label: Label
var icon: Control


func bind_clock(c: SimulationClock) -> void:
	clock = c


func _ready() -> void:
	icon = Glyph.new()
	icon.custom_minimum_size = ICON_SIZE
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	add_child(icon)
	label = Label.new()
	label.add_theme_font_size_override("font_size", 18)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(label)
	refresh()


func _process(_delta: float) -> void:
	refresh()


func is_night() -> bool:
	return clock != null and GameTime.is_night(clock.tick_index)


func refresh() -> void:
	if clock == null or label == null:
		return
	var t := GameTime.label(clock.tick_index)
	if label.text != t:
		label.text = t
	var night := is_night()
	if (icon as Glyph).night != night:
		(icon as Glyph).night = night
		icon.tooltip_text = "Night" if night else "Day"
		icon.queue_redraw()


class Glyph extends Control:
	const SUN := Color(1.0, 0.82, 0.3)
	const MOON := Color(0.8, 0.85, 1.0)
	var night := false

	func _draw() -> void:
		var c := size / 2.0
		var r := minf(size.x, size.y) * 0.38
		if night:
			# Crescent: outer arc on the left, inner arc back on the right.
			var pts := PackedVector2Array()
			for i in 13:
				var a := deg_to_rad(60.0 + 240.0 * i / 12.0)
				pts.append(c + Vector2.RIGHT.rotated(a) * r)
			var ic := c + Vector2(r * 0.55, 0)
			for i in 13:
				var a := deg_to_rad(240.0 - 120.0 * i / 12.0)
				pts.append(ic + Vector2.RIGHT.rotated(a) * r * 0.85)
			draw_colored_polygon(pts, MOON)
		else:
			for i in 8:
				var d := Vector2.RIGHT.rotated(TAU * i / 8.0)
				draw_line(c + d * r * 1.15, c + d * r * 1.45, SUN, 2.0)
			draw_circle(c, r * 0.9, SUN)
