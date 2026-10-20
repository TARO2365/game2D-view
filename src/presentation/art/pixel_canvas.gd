class_name PixelCanvas
extends RefCounted
## Tiny RGBA8 software canvas used to generate procedural art once (tiles,
## ladder). Writes into a PackedByteArray (much faster than Image.set_pixel
## from GDScript) with source-over alpha blending. Deterministic.

var w := 0
var h := 0
var data := PackedByteArray()


func _init(width: int, height: int) -> void:
	w = width
	h = height
	data.resize(w * h * 4)
	data.fill(0)


func get_px(x: int, y: int) -> Color:
	var i := (y * w + x) * 4
	return Color8(data[i], data[i + 1], data[i + 2], data[i + 3])


## Source-over blend of `c` onto pixel (x, y); out-of-bounds is ignored.
func put(x: int, y: int, c: Color) -> void:
	if x < 0 or y < 0 or x >= w or y >= h or c.a <= 0.0:
		return
	var i := (y * w + x) * 4
	if c.a >= 1.0:
		data[i] = c.r8
		data[i + 1] = c.g8
		data[i + 2] = c.b8
		data[i + 3] = 255
		return
	var da := data[i + 3] / 255.0
	var oa := c.a + da * (1.0 - c.a)
	if oa <= 0.0:
		return
	var k := da * (1.0 - c.a)
	data[i] = clampi(roundi((c.r * c.a * 255.0 + data[i] * k) / oa), 0, 255)
	data[i + 1] = clampi(roundi((c.g * c.a * 255.0 + data[i + 1] * k) / oa), 0, 255)
	data[i + 2] = clampi(roundi((c.b * c.a * 255.0 + data[i + 2] * k) / oa), 0, 255)
	data[i + 3] = clampi(roundi(oa * 255.0), 0, 255)


## Multiplies RGB of an existing pixel by f (keeps alpha).
func shade(x: int, y: int, f: float) -> void:
	if x < 0 or y < 0 or x >= w or y >= h:
		return
	var i := (y * w + x) * 4
	data[i] = clampi(roundi(data[i] * f), 0, 255)
	data[i + 1] = clampi(roundi(data[i + 1] * f), 0, 255)
	data[i + 2] = clampi(roundi(data[i + 2] * f), 0, 255)


func rect(x: int, y: int, rw: int, rh: int, c: Color) -> void:
	for yy in range(maxi(y, 0), mini(y + rh, h)):
		for xx in range(maxi(x, 0), mini(x + rw, w)):
			put(xx, yy, c)


func ellipse(cx: float, cy: float, rx: float, ry: float, c: Color) -> void:
	if rx <= 0.0 or ry <= 0.0:
		return
	for yy in range(maxi(floori(cy - ry), 0), mini(ceili(cy + ry) + 1, h)):
		for xx in range(maxi(floori(cx - rx), 0), mini(ceili(cx + rx) + 1, w)):
			var dx := (xx + 0.5 - cx) / rx
			var dy := (yy + 0.5 - cy) / ry
			if dx * dx + dy * dy <= 1.0:
				put(xx, yy, c)


## Filled diamond (crystal facet). `light` colours the left half.
func diamond(cx: float, cy: float, hw: float, hh: float, c: Color, light: Color) -> void:
	for yy in range(maxi(floori(cy - hh), 0), mini(ceili(cy + hh) + 1, h)):
		for xx in range(maxi(floori(cx - hw), 0), mini(ceili(cx + hw) + 1, w)):
			var dx := (xx + 0.5 - cx) / hw
			var dy := (yy + 0.5 - cy) / hh
			if absf(dx) + absf(dy) <= 1.0:
				put(xx, yy, light if dx < 0.0 else c)


func line(x0: int, y0: int, x1: int, y1: int, c: Color) -> void:
	var dx := absi(x1 - x0)
	var dy := -absi(y1 - y0)
	var sx := 1 if x0 < x1 else -1
	var sy := 1 if y0 < y1 else -1
	var err := dx + dy
	while true:
		put(x0, y0, c)
		if x0 == x1 and y0 == y1:
			break
		var e2 := 2 * err
		if e2 >= dy:
			err += dy
			x0 += sx
		if e2 <= dx:
			err += dx
			y0 += sy


func to_image() -> Image:
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, data)


# --- Deterministic noise ------------------------------------------------------

## Integer hash -> 0..1.
static func hash01(x: int, y: int, s: int) -> float:
	var n := ((x * 374761393) ^ (y * 668265263) ^ (s * 1442695041)) & 0x7FFFFFFF
	n = ((n ^ (n >> 13)) * 1274126177) & 0x7FFFFFFF
	n = n ^ (n >> 16)
	return float(n & 0xFFFF) / 65535.0


## Smooth value noise that tiles every `period` pixels (period % cell == 0).
static func vnoise(x: float, y: float, cell: int, period: int, s: int) -> float:
	var g := maxi(1, period / cell)
	var gx := x / cell
	var gy := y / cell
	var ix := floori(gx)
	var iy := floori(gy)
	var fx := gx - ix
	var fy := gy - iy
	fx = fx * fx * (3.0 - 2.0 * fx)
	fy = fy * fy * (3.0 - 2.0 * fy)
	var a := hash01(posmod(ix, g), posmod(iy, g), s)
	var b := hash01(posmod(ix + 1, g), posmod(iy, g), s)
	var c := hash01(posmod(ix, g), posmod(iy + 1, g), s)
	var d := hash01(posmod(ix + 1, g), posmod(iy + 1, g), s)
	return lerpf(lerpf(a, b, fx), lerpf(c, d, fx), fy)
