class_name WorldSession
extends RefCounted
## Everything that belongs to the one currently loaded world (D-014).
## Composition only: each part keeps ownership of its own state
## (contract docs/contracts/M2_CONTRACTS.md §1).

## id, name, seed, preset, size (Vector2i), gen_version, created_unix, last_played_unix
var meta: Dictionary = {}
var grid: WorldGrid
var designations: DesignationMap
var inventory: Inventory
var stockpiles: StockpileZones
var clock := SimulationClock.new()
var ids := StableIdAllocator.new()


static func create_new(world_meta: Dictionary, registry: TileRegistry) -> WorldSession:
	var grid := WorldGenerator.generate(int(world_meta["seed"]), world_meta["size"], registry)
	return from_grid(world_meta, grid)


## Builds all systems around an existing grid (new world or loaded save).
static func from_grid(world_meta: Dictionary, world_grid: WorldGrid) -> WorldSession:
	var s := WorldSession.new()
	s.meta = world_meta.duplicate()
	s.grid = world_grid
	s.designations = DesignationMap.new(s.grid)
	s.inventory = Inventory.new(s.ids)
	s.stockpiles = StockpileZones.new(s.grid, s.inventory)
	return s


func world_id() -> String:
	return meta.get("id", "")
