class_name WorldSession
extends RefCounted
## Everything that belongs to the one currently loaded world (D-014).
## Composition only: each part keeps ownership of its own state
## (contract docs/contracts/M2_CONTRACTS.md §1). The simulation runs on
## SimulationClock ticks (M4a contract §8): farming, jobs, colony, then the
## alert refresh.

const SCALE_CONFIG_PATH := "res://data/config/scale_config.tres"
## Starting food (D-028 P-6): about 3 days for 3 NPCs. PLACEHOLDER.
const STARTING_RATION_KG := 20.0

## id, name, seed, preset, size (Vector2i), gen_version, created_unix, last_played_unix
var meta: Dictionary = {}
var grid: WorldGrid
var designations: DesignationMap
var inventory: Inventory
var stockpiles: StockpileZones
var buildings: Buildings
var rooms: RoomMap
var materials: MaterialDefs
var crates: CrateStorage
var farming: Farming
var kitchens: Kitchens
var build_orders: BuildOrders
var nav: NavGrid
var jobs: JobManager
var colony: Colony
var alerts := AlertService.new()
var clock := SimulationClock.new()
var ids := StableIdAllocator.new()


static func create_new(world_meta: Dictionary, registry: TileRegistry) -> WorldSession:
	var grid := WorldGenerator.generate(int(world_meta["seed"]), world_meta["size"], registry)
	var s := from_grid(world_meta, grid)
	s.colony.spawn_starting_npcs()
	s._spawn_starting_supplies()
	return s


## Builds all systems around an existing grid (new world or loaded save).
static func from_grid(world_meta: Dictionary, world_grid: WorldGrid) -> WorldSession:
	var s := WorldSession.new()
	s.meta = world_meta.duplicate()
	s.grid = world_grid
	# Buildings first: it registers itself as the grid's building query, which
	# DesignationMap and WorldGrid edits consult (M3 contract §2, §6).
	s.buildings = Buildings.new(s.grid, s.ids)
	s.designations = DesignationMap.new(s.grid)
	s.inventory = Inventory.new(s.ids)
	s.stockpiles = StockpileZones.new(s.grid, s.inventory)
	s.rooms = RoomMap.new(s.grid, s.buildings)
	s.materials = MaterialDefs.load_default()
	s.crates = CrateStorage.new(s.buildings, s.inventory, s.materials)
	s.farming = Farming.new(s.buildings, s.inventory, s.ids)
	s.kitchens = Kitchens.new(s.buildings, s.inventory)
	s.build_orders = BuildOrders.new(s.grid, s.buildings, s.designations, s.ids)
	var config := load(SCALE_CONFIG_PATH) as ScaleConfig
	s.nav = NavGrid.new(s.grid, config.clearance_standard_tiles)
	s.jobs = JobManager.new(s.grid, s.designations, s.inventory, s.stockpiles, s.nav, s.ids,
			s.buildings, s.crates, s.build_orders)
	s.colony = Colony.new(s.grid, s.nav, s.jobs, s.ids, int(world_meta.get("seed", 0)))
	s.clock.ticked.connect(s.simulate_tick)
	return s


func simulate_tick(tick: int) -> void:
	alerts.current_tick = tick
	farming.update(tick)
	jobs.update(tick)
	colony.update(tick)


func world_id() -> String:
	return meta.get("id", "")


## Starting ration stack next to the first colonist; haulers store it once
## the player builds a crate or stockpile.
func _spawn_starting_supplies() -> void:
	var npcs := colony.all_npcs()
	if npcs.is_empty():
		return
	var at: Vector2i = npcs[0].tile
	for dx in [2, -2, 3, -3, 1, -1, 0]:
		var t: Vector2i = at + Vector2i(dx, 0)
		if grid.in_bounds(t) and grid.is_passable(t) and grid.is_solid_at(t + Vector2i.DOWN):
			at = t
			break
	inventory.spawn_ground(&"ration", STARTING_RATION_KG, at)
