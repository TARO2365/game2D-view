extends RefCounted
## Test-only filesystem helpers (temp folders under user://).


static func temp_root(tag: String) -> String:
	return "user://test_%s_%d" % [tag, Time.get_ticks_usec()]


static func rm_rf(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	for sub in d.get_directories():
		rm_rf(path.path_join(sub))
	DirAccess.remove_absolute(path)


static func write_bytes(path: String, data: PackedByteArray) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(data)
	f.close()


## Small hand-made grid: rows < 10 air, then dirt, bottom row bedrock.
static func make_grid(reg: TileRegistry, size: Vector2i = Vector2i(64, 64)) -> WorldGrid:
	var g := WorldGrid.new(size.x, size.y, reg)
	var t := PackedByteArray()
	t.resize(size.x * size.y)
	for y in size.y:
		var id := TileRegistry.AIR
		if y == size.y - 1:
			id = TileRegistry.BEDROCK
		elif y >= 10:
			id = TileRegistry.DIRT
		for x in size.x:
			t[y * size.x + x] = id
	g.tiles = t
	for x in size.x:
		g.surface_y[x] = 10
	return g
