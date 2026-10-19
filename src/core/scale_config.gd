class_name ScaleConfig
extends Resource
## World/visual scale assumptions. WORKING ASSUMPTIONS from the approved concept
## sheets (DECISIONS.md D-003); final values are set by the Visual Design Phase.
## Gameplay code must read these values instead of hard-coding pixels.

## Size of one world tile in pixels at zoom 1.0.
@export var tile_size_px: int = 64
## Vertical clearance (tiles) an agent needs to stand/walk through a space.
## standard: NPCs (~2.5 tiles tall) and ordinary surface zombies (~3 tiles).
@export var clearance_small_tiles: int = 1
@export var clearance_standard_tiles: int = 3
@export var clearance_large_tiles: int = 4
## Sprite pivot convention: bottom-center of the agent's feet tile.
@export var sprite_pivot: String = "bottom_center"
## Texture filter for world art. PENDING Visual Design (nearest vs linear).
@export var world_texture_filter: String = "TBD"


func tiles_to_px(tiles: float) -> float:
	return tiles * tile_size_px


func px_to_tiles(px: float) -> float:
	return px / tile_size_px
