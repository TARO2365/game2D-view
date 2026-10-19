extends GutTest


func test_config_resource_loads_working_assumptions() -> void:
	var cfg := load("res://data/config/scale_config.tres") as ScaleConfig
	assert_not_null(cfg)
	assert_eq(cfg.tile_size_px, 64)
	assert_eq(cfg.clearance_standard_tiles, 3)
	assert_eq(cfg.sprite_pivot, "bottom_center")


func test_conversions() -> void:
	var cfg := ScaleConfig.new()
	assert_eq(cfg.tiles_to_px(2.5), 160.0)
	assert_eq(cfg.px_to_tiles(192.0), 3.0)
