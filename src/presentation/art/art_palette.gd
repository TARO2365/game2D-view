class_name ArtPalette
extends RefCounted
## Colour palette sampled from the approved concept sheets (D-002,
## docs/visual/concept/*.png). docs/art/ASSET_SPEC.md §3 lists the same values.

# Concept "Color Palette" swatches (04_miner_sheet.png).
const HELMET_YELLOW := Color("#fcb639")
const SAFETY_ORANGE := Color("#d76729")
const LEATHER_BROWN := Color("#603b29")
const DUST_BEIGE := Color("#b8a395")
const SLATE := Color("#3b404c")
const CHARCOAL := Color("#302929")
const NIGHT_NAVY := Color("#1c232b")
const STEEL_BLUE := Color("#4b6288")
const SKY_BLUE := Color("#63add8")

# Outlines / shading.
const OUTLINE := Color("#1e1712")
const SHADOW := Color(0.0, 0.0, 0.0, 0.32)

# Terrain bases (01_gameplay_mockup_a.png "Environment tiles").
const DIRT := Color("#7a5638")
const DIRT_DARK := Color("#5a3f2a")
const DIRT_LIGHT := Color("#977254")
const ROCK := Color("#67615b")
const ROCK_DARK := Color("#433e3a")
const ROCK_LIGHT := Color("#91887d")
const IRON := Color("#4b6288")
const IRON_LIGHT := Color("#8fd0f2")
const GOLD := Color("#e5a82e")
const GOLD_DARK := Color("#7a4f12")
const GOLD_LIGHT := Color("#fff0a0")
const CRYSTAL := Color("#a24fd6")
const CRYSTAL_DARK := Color("#4a2260")
const CRYSTAL_LIGHT := Color("#efc0ff")
const BEDROCK := Color("#2e292b")
const BEDROCK_LIGHT := Color("#4a4245")
const CONCRETE := Color("#8a8e93")
const CONCRETE_DARK := Color("#62666b")
const CONCRETE_LIGHT := Color("#adb1b5")
const WOOD := Color("#8a5a2b")
const WOOD_DARK := Color("#4a2e16")
const WOOD_LIGHT := Color("#b9824a")

# Characters.
const SKIN_TONES: Array[Color] = [
	Color("#f6d2b0"), Color("#ecc097"), Color("#d9a477"), Color("#b97e52"), Color("#8d5a37"),
]
const HAIR_COLORS: Array[Color] = [
	Color("#3a2618"), Color("#5a3820"), Color("#1d1a1e"), Color("#7a4a26"), Color("#c9c3bb"), Color("#2b2233"),
]
const EYE := Color("#2a1d18")
const BLUSH := Color(0.95, 0.45, 0.45, 0.35)
const BOOT := Color("#4a3020")
const COAT_WHITE := Color("#eef0ee")
const LAMP := Color("#fff3b0")
