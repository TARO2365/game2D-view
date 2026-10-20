extends SceneTree
## Benchmark: world generation, save and load per preset.
## Usage: godot --headless --path . -s res://tools/bench_world.gd

const ROOT := "user://bench_worlds"


func _init() -> void:
	var reg := TileRegistry.load_default()
	print("preset   size        gen_ms   save_ms  save_kb  load_ms  hash")
	for key in WorldGenerator.PRESETS:
		var size: Vector2i = WorldGenerator.PRESETS[key]
		var t0 := Time.get_ticks_usec()
		var s := WorldSession.create_new({"id": "wbench", "name": "b", "seed": 12345, "size": size}, reg)
		var gen_ms := (Time.get_ticks_usec() - t0) / 1000.0
		# Simulate a played world: dig ~2% of tiles spread over many chunks.
		for i in 40:
			s.grid.apply_edit(Rect2i((i * 37) % (size.x - 20), size.y / 3 + (i * 13) % (size.y / 2), 16, 8),
					WorldGrid.Edit.DIG)
		var dir := ROOT.path_join(String(key))
		DirAccess.make_dir_recursive_absolute(dir)
		var sv := SaveService.save(s, dir, SaveService.Kind.MANUAL)
		t0 = Time.get_ticks_usec()
		var ld := SaveService.load_world(dir, reg, s.meta)
		var load_ms := (Time.get_ticks_usec() - t0) / 1000.0
		print("%-8s %4dx%-4d  %7.1f  %7.1f  %7.1f  %7.1f  %s %s" % [key, size.x, size.y, gen_ms,
				sv.data.get("ms", -1.0), sv.data.get("bytes", 0) / 1024.0, load_ms,
				s.grid.world_hash().left(12), "OK" if ld.ok else "LOAD FAILED"])
	print("static memory MB: %.1f" % (OS.get_static_memory_usage() / 1048576.0))
	quit()
