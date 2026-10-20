class_name WorldSession
extends RefCounted
## Everything that belongs to the one currently loaded world (D-014).
## Composition only: each part keeps ownership of its own state.

## id, name, seed, preset, size (Vector2i), gen_version, created_unix, last_played_unix
var meta: Dictionary = {}
var grid: WorldGrid
var designations: DesignationMap
var clock := SimulationClock.new()
var ids := StableIdAllocator.new()


static func create_new(world_meta: Dictionary, registry: TileRegistry) -> WorldSession:
	var s := WorldSession.new()
	s.meta = world_meta.duplicate()
	s.grid = WorldGenerator.generate(int(world_meta["seed"]), world_meta["size"], registry)
	s.designations = DesignationMap.new(s.grid)
	return s


func world_id() -> String:
	return meta.get("id", "")
