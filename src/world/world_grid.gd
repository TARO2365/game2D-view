class_name WorldGrid
extends RefCounted
## Authoritative terrain of one finite world (spec §2). The whole world lives
## in memory, so simulation never depends on what the camera shows; rendering
## streams chunks separately (WorldView).
## Mutations go through apply_edit() / apply_structure(), which validate and
## emit tiles_changed with the exact changed rect so dependants update only
## that region. Two layers: terrain `tiles` and `structures` (ladders) that
## sit in air tiles.

signal tiles_changed(rect: Rect2i)

enum Edit { DIG, BUILD_WALL }
## Stored in save files: NEVER renumber or reuse a value.
enum Structure { NONE = 0, LADDER = 1 }

const CHUNK_SIZE := 32  # tiles per chunk side. PLACEHOLDER (spec §17).

var width: int
var height: int
var registry: TileRegistry
## One byte per tile = TileRegistry id, row-major.
var tiles := PackedByteArray()
## One byte per tile = Structure value, row-major, same size as tiles.
## Invariant: a structure only exists on an air tile.
var structures := PackedByteArray()
## First solid row of each column at generation time. Derived; not saved.
var surface_y := PackedInt32Array()

var _modified_chunks: Dictionary = {}  # chunk index -> true


func _init(w: int, h: int, reg: TileRegistry) -> void:
	width = w
	height = h
	registry = reg
	tiles.resize(w * h)
	structures.resize(w * h)
	surface_y.resize(w)


func get_size() -> Vector2i:
	return Vector2i(width, height)


func bounds() -> Rect2i:
	return Rect2i(0, 0, width, height)


func in_bounds(p: Vector2i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.x < width and p.y < height


func get_tile(p: Vector2i) -> int:
	return tiles[p.y * width + p.x]


func get_structure(p: Vector2i) -> int:
	return structures[p.y * width + p.x]


func is_ladder(p: Vector2i) -> bool:
	return in_bounds(p) and structures[p.y * width + p.x] == Structure.LADDER


## In bounds and not solid. Ladders do not block movement.
func is_passable(p: Vector2i) -> bool:
	return in_bounds(p) and not registry.is_solid(tiles[p.y * width + p.x])


## Out of bounds counts as solid (the world edge is a wall).
func is_solid_at(p: Vector2i) -> bool:
	return not in_bounds(p) or registry.is_solid(tiles[p.y * width + p.x])


func can_dig(tile_id: int) -> bool:
	return registry.is_diggable(tile_id)


func can_build(tile_id: int) -> bool:
	return tile_id == TileRegistry.AIR


## Validated terrain edit. In normal play this is only called by NPC jobs
## (M2+); in M1 only the debug instant-edit tool calls it (D-015).
func apply_edit(rect: Rect2i, edit: Edit) -> CommandResult:
	var r := rect.intersection(bounds())
	if not r.has_area():
		return CommandResult.failure(&"out_of_bounds", "Selection is outside the world")
	var target := TileRegistry.AIR if edit == Edit.DIG else TileRegistry.CONCRETE
	var changed := 0
	var min_p := Vector2i(width, height)
	var max_p := Vector2i(-1, -1)
	for y in range(r.position.y, r.end.y):
		var row := y * width
		for x in range(r.position.x, r.end.x):
			var cur: int = tiles[row + x]
			# Walls never replace a structure. Solid tiles never hold one, so DIG is unaffected.
			var ok := can_dig(cur) if edit == Edit.DIG \
					else (can_build(cur) and structures[row + x] == Structure.NONE)
			if not ok:
				continue
			tiles[row + x] = target
			changed += 1
			min_p = Vector2i(mini(min_p.x, x), mini(min_p.y, y))
			max_p = Vector2i(maxi(max_p.x, x), maxi(max_p.y, y))
			_modified_chunks[chunk_index(Vector2i(x / CHUNK_SIZE, y / CHUNK_SIZE))] = true
	if changed == 0:
		return CommandResult.failure(&"nothing_to_change",
				"Nothing in the selection can be %s" % ("dug" if edit == Edit.DIG else "built on"),
				{"skipped": r.get_area()})
	var changed_rect := Rect2i(min_p, max_p - min_p + Vector2i.ONE)
	tiles_changed.emit(changed_rect)
	return CommandResult.success({"changed": changed, "skipped": r.get_area() - changed,
			"rect": changed_rect})


# --- Structures ---------------------------------------------------------

func can_place_structure(p: Vector2i, s: Structure) -> bool:
	if s == Structure.NONE or not in_bounds(p):
		return false
	var i := p.y * width + p.x
	return tiles[i] == TileRegistry.AIR and structures[i] == Structure.NONE


## Validated structure placement (JobManager calls it when a build finishes).
func apply_structure(p: Vector2i, s: Structure) -> CommandResult:
	if not in_bounds(p):
		return CommandResult.failure(&"out_of_bounds", "Tile is outside the world")
	if s == Structure.NONE:
		return CommandResult.failure(&"invalid_structure", "No structure given")
	var i := p.y * width + p.x
	if structures[i] != Structure.NONE:
		return CommandResult.failure(&"occupied", "A structure is already there")
	if tiles[i] != TileRegistry.AIR:
		return CommandResult.failure(&"blocked", "Structures need an open tile")
	structures[i] = s
	_structure_changed(p)
	return CommandResult.success({"rect": Rect2i(p, Vector2i.ONE)})


func remove_structure(p: Vector2i) -> CommandResult:
	if not in_bounds(p):
		return CommandResult.failure(&"out_of_bounds", "Tile is outside the world")
	var i := p.y * width + p.x
	if structures[i] == Structure.NONE:
		return CommandResult.failure(&"nothing_to_change", "No structure there")
	structures[i] = Structure.NONE
	_structure_changed(p)
	return CommandResult.success({"rect": Rect2i(p, Vector2i.ONE)})


func _structure_changed(p: Vector2i) -> void:
	_modified_chunks[chunk_index(p / CHUNK_SIZE)] = true
	tiles_changed.emit(Rect2i(p, Vector2i.ONE))


# --- Chunks -------------------------------------------------------------

func chunks_x() -> int:
	return (width + CHUNK_SIZE - 1) / CHUNK_SIZE


func chunks_y() -> int:
	return (height + CHUNK_SIZE - 1) / CHUNK_SIZE


func chunk_count() -> int:
	return chunks_x() * chunks_y()


func chunk_index(c: Vector2i) -> int:
	return c.y * chunks_x() + c.x


func chunk_coords_of_index(i: int) -> Vector2i:
	return Vector2i(i % chunks_x(), i / chunks_x())


func chunk_rect(c: Vector2i) -> Rect2i:
	return Rect2i(c * CHUNK_SIZE, Vector2i.ONE * CHUNK_SIZE).intersection(bounds())


func chunks_in_rect(rect: Rect2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var r := rect.intersection(bounds())
	if not r.has_area():
		return out
	var c0 := r.position / CHUNK_SIZE
	var c1 := (r.end - Vector2i.ONE) / CHUNK_SIZE
	for cy in range(c0.y, c1.y + 1):
		for cx in range(c0.x, c1.x + 1):
			out.append(Vector2i(cx, cy))
	return out


## Chunk save data: all tile bytes of the chunk, then all structure bytes
## (2 x area, row-major within the chunk).
func get_chunk_bytes(c: Vector2i) -> PackedByteArray:
	var r := chunk_rect(c)
	var out := PackedByteArray()
	for layer: PackedByteArray in [tiles, structures]:
		for y in range(r.position.y, r.end.y):
			var start := y * width + r.position.x
			out.append_array(layer.slice(start, start + r.size.x))
	return out


## Restores a chunk from save data (no tiles_changed: used before rendering).
## Accepts 2 x area (tiles + structures) or 1 x area (save v1: tiles only;
## the chunk's structures are cleared).
func set_chunk_bytes(c: Vector2i, data: PackedByteArray) -> bool:
	if c.x < 0 or c.y < 0 or c.x >= chunks_x() or c.y >= chunks_y():
		return false
	var r := chunk_rect(c)
	var area := r.get_area()
	var with_structures := data.size() == 2 * area
	if not with_structures and data.size() != area:
		return false
	var i := 0
	for y in range(r.position.y, r.end.y):
		var row := y * width
		for x in range(r.position.x, r.end.x):
			tiles[row + x] = data[i]
			structures[row + x] = data[area + i] if with_structures else Structure.NONE
			i += 1
	_modified_chunks[chunk_index(c)] = true
	return true


## Chunk indices changed since generation (only these are saved).
func modified_chunks() -> Array[int]:
	var out: Array[int] = []
	for k in _modified_chunks:
		out.append(k)
	out.sort()
	return out


## Terrain only; the generator golden-hash test uses this.
func terrain_hash() -> String:
	return Hashing.sha256_hex(tiles)


## Full world state: sha256 of tiles followed by structures (save integrity).
func world_hash() -> String:
	return Hashing.sha256_hex(tiles + structures)
