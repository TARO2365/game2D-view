class_name AlertsPanel
extends PanelContainer
## Colony alerts (spec §9) grouped by severity (emergency red, important
## orange, general grey) with a count badge. The newest emergency pulses for
## a few seconds. Clicking a row emits alert_clicked; GameScreen centres the
## camera on its NPC / tile. Read-only view of AlertService.

signal alert_clicked(alert: Dictionary)

const PANEL_WIDTH := 300.0        # PLACEHOLDER
const LIST_HEIGHT := 132.0        # 3 rows of 44 px visible, then scroll
const PULSE_SECONDS := 4.0        # PLACEHOLDER
const GROUP_NAMES := {2: "Emergency", 1: "Important", 0: "General"}

var alerts: AlertService
var header_label: Label
var badge: Label
var list: VBoxContainer
## key -> Button (tests)
var rows: Dictionary = {}
## Key of the emergency currently pulsing ("" = none).
var pulsing_key := ""

var _dirty := true
var _pulse_left := 0.0
var _seen_emergencies: Dictionary = {}
var _scroll: ScrollContainer


func setup(service: AlertService) -> void:
	alerts = service
	alerts.alerts_changed.connect(func() -> void: _dirty = true)


func _ready() -> void:
	custom_minimum_size = Vector2(PANEL_WIDTH, 0)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var sb := UiStyle.panel_box()
	sb.set_content_margin_all(6)
	add_theme_stylebox_override("panel", sb)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	add_child(box)
	var head := HBoxContainer.new()
	box.add_child(head)
	header_label = Label.new()
	header_label.text = "Alerts"
	header_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(header_label)
	badge = Label.new()
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.custom_minimum_size = Vector2(28, 0)
	var bs := StyleBoxFlat.new()
	bs.bg_color = UiStyle.severity_color(2)
	bs.set_corner_radius_all(10)
	bs.set_content_margin_all(2)
	badge.add_theme_stylebox_override("normal", bs)
	head.add_child(badge)
	_scroll = ScrollContainer.new()
	_scroll.custom_minimum_size = Vector2(0, LIST_HEIGHT)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(_scroll)
	list = VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 2)
	_scroll.add_child(list)
	rebuild()


func _process(delta: float) -> void:
	if _dirty:
		rebuild()
	if _pulse_left > 0.0:
		_pulse_left -= delta
		var row: Button = rows.get(pulsing_key)
		if row:
			var a := 0.55 + 0.45 * absf(sin(_pulse_left * 6.0))
			row.modulate = Color(1, 1, 1, a) if _pulse_left > 0.0 else Color.WHITE
		if _pulse_left <= 0.0:
			pulsing_key = ""


func rebuild() -> void:
	_dirty = false
	if list == null:
		return
	for c in list.get_children():
		list.remove_child(c)
		c.queue_free()
	rows.clear()
	var all := alerts.alerts()
	badge.text = str(all.size())
	badge.visible = not all.is_empty()
	var top := 0
	for a in all:
		top = maxi(top, int(a["severity"]))
	(badge.get_theme_stylebox("normal") as StyleBoxFlat).bg_color = UiStyle.severity_color(top)
	var group := -1
	var newest := {}
	for a in all:
		var sev := int(a["severity"])
		if sev != group:
			group = sev
			var g := Label.new()
			g.text = GROUP_NAMES.get(sev, "")
			g.add_theme_font_size_override("font_size", 13)
			g.add_theme_color_override("font_color", UiStyle.severity_color(sev))
			list.add_child(g)
		var b := Button.new()
		b.text = a["message"]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.clip_text = true
		b.custom_minimum_size = Vector2(0, 44)
		b.tooltip_text = a["message"]
		b.add_theme_color_override("font_color", UiStyle.severity_color(sev))
		var sbn := StyleBoxFlat.new()
		sbn.bg_color = Color(UiStyle.severity_color(sev), 0.16)
		sbn.border_color = UiStyle.severity_color(sev)
		sbn.border_width_left = 4
		sbn.set_content_margin_all(6)
		b.add_theme_stylebox_override("normal", sbn)
		var alert: Dictionary = a
		b.pressed.connect(func() -> void: alert_clicked.emit(alert))
		list.add_child(b)
		rows[a["key"]] = b
		if sev == AlertService.Severity.EMERGENCY and not _seen_emergencies.has(a["key"]):
			if newest.is_empty() or int(a["since_tick"]) >= int(newest["since_tick"]):
				newest = a
	var keys: Dictionary = {}
	for a in all:
		if int(a["severity"]) == AlertService.Severity.EMERGENCY:
			keys[a["key"]] = true
	for k in keys:
		_seen_emergencies[k] = true
	for k in _seen_emergencies.keys():
		if not keys.has(k):
			_seen_emergencies.erase(k)  # cleared: pulses again if it comes back
	if not newest.is_empty():
		pulsing_key = newest["key"]
		_pulse_left = PULSE_SECONDS
	if all.is_empty():
		var none := Label.new()
		none.text = "No alerts"
		none.add_theme_color_override("font_color", UiStyle.severity_color(0))
		list.add_child(none)
