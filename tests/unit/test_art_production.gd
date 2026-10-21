extends GutTest
## Every committed production image matches ASSET_SPEC sizes and is found by
## ArtLibrary under its spec name (import check for owner art, D-020).

const ROOT := "res://assets/production/"


func before_each() -> void:
	ArtLibrary.base_dir = ROOT
	ArtLibrary.clear_cache()


func _pngs(sub: String) -> Array[String]:
	var out: Array[String] = []
	if DirAccess.dir_exists_absolute(ROOT + sub):
		for f in DirAccess.get_files_at(ROOT + sub):
			if f.ends_with(".png"):
				out.append(f)
	return out


func test_terrain_strips() -> void:
	for f in _pngs("terrain"):
		var key := StringName(f.get_basename().trim_prefix("terrain_"))
		var strip := ArtLibrary.terrain_strip(key, 64)
		assert_not_null(strip, f)
		if strip:
			assert_eq(strip.get_height(), 64, f)
			assert_eq(strip.get_width() % 64, 0, f)
			assert_eq(strip.get_pixel(10, 10).a, 1.0, "%s opaque" % f)


func test_character_sheets() -> void:
	var n := 0
	for f in _pngs("characters"):
		var parts := f.get_basename().split("_")
		var sheet := ArtLibrary.npc_sheet(StringName(parts[1]), StringName(parts[2]))
		assert_not_null(sheet, f)
		if sheet:
			n += 1
			assert_eq(sheet.get_height(), ArtLibrary.NPC_CELL.y, f)
			assert_eq(sheet.get_width() % ArtLibrary.NPC_CELL.x, 0, f)
			var img := ArtLibrary.image(ArtLibrary.npc_sheet_path(StringName(parts[1]), StringName(parts[2])))
			for i in ArtLibrary.frame_count(sheet):
				var used := img.get_region(Rect2i(i * ArtLibrary.NPC_CELL.x, 0, ArtLibrary.NPC_CELL.x, ArtLibrary.NPC_CELL.y)).get_used_rect()
				assert_gt(used.size.y, 100, "%s frame %d has a figure" % [f, i])
				assert_gte(used.end.y, ArtLibrary.NPC_CELL.y - 2, "%s frame %d feet on the bottom edge" % [f, i])
	gut.p("character sheets checked: %d" % n)


func test_ladder_tile() -> void:
	if not FileAccess.file_exists(ROOT + "structures/ladder.png"):
		pass_test("no production ladder")
		return
	var img := ArtLibrary.tile_image(ArtLibrary.structure_path(&"ladder"), 64)
	assert_not_null(img)
	assert_eq(img.get_size(), Vector2i(64, 64))
