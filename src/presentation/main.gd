extends Node
## App shell / composition root: owns WorldSlots and swaps between the main
## menu and the game screen. Only one world is loaded at a time (D-014).
## No autoload singletons (D-010).

const MENU_SCENE := preload("res://scenes/main_menu.tscn")
const GAME_SCENE := preload("res://scenes/game.tscn")
const SCALE_CONFIG_PATH := "res://data/config/scale_config.tres"

## Set before the node enters the tree to use another folder (tests).
var worlds_root := WorldSlots.DEFAULT_ROOT
var registry: TileRegistry
var slots: WorldSlots
var scale_config: ScaleConfig
var current_screen: Node


func _ready() -> void:
	registry = TileRegistry.load_default()
	scale_config = load(SCALE_CONFIG_PATH) as ScaleConfig
	slots = WorldSlots.new(registry, worlds_root)
	show_menu()


func show_menu() -> MainMenu:
	var menu := MENU_SCENE.instantiate() as MainMenu
	menu.setup(slots)
	menu.play_requested.connect(start_game)
	_swap(menu)
	return menu


func start_game(session: WorldSession, notice: String = "") -> GameScreen:
	var game := GAME_SCENE.instantiate() as GameScreen
	game.setup(session, slots, scale_config, notice)
	game.quit_requested.connect(show_menu)
	_swap(game)
	return game


func _swap(screen: Node) -> void:
	if current_screen:
		remove_child(current_screen)
		current_screen.queue_free()
	current_screen = screen
	add_child(screen)
