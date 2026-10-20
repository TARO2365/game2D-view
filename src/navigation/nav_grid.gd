class_name NavGrid
extends RefCounted
## Tile navigation for standard-clearance agents (NPCs, D-003 / D-017).
## An agent's position is its feet tile F; its body is F, F-1 .. F-(clearance-1)
## (y grows downward). Movement rules (M2 contract §7, plan P-2):
##   walk        (x±1, y)        both body columns free, floor at the destination
##   step up     (x±1, y-1)      also needs headroom (x, y-clearance)
##   step down   (x±1, y+1)      column x±1 from y-(clearance-1) to y+1 free
##   drop        (x±1, y+k) k=2..MAX_DROP, same column rule down to y+k
##   ladder      (x, y±1)        source or destination is a ladder
## Agents never climb walls. A* is weighted (heuristic = Manhattan × step cost):
## paths are good, not guaranteed optimal (simulation determinism is not
## required in M2, D-017). The shared per-tick path-search budget lives here
## because JobManager (assignment) and Colony (repaths) both search.
##
## Standability is cached per tile and invalidated only in the region a
## `tiles_changed` rect can affect. Call invalidate_all() after bulk changes
## that bypass the signal (e.g. WorldGrid.set_chunk_bytes on load).

const TICKS_PER_STEP := 5          # PLACEHOLDER walk/step ≈ 2 tiles/s at 10 Hz (D-017)
const TICKS_PER_LADDER_STEP := 7   # PLACEHOLDER
const TICKS_PER_DROP_TILE := 2     # PLACEHOLDER
const MAX_DROP := 4                # D-017: drops of more than 4 tiles are not allowed
const PATH_BUDGET_PER_TICK := 8    # PLACEHOLDER path searches per tick across all NPCs
const EXPANSION_BUDGET_PER_TICK := 4000  # PLACEHOLDER A* expansions per tick (spike cap, QA-2)
const DEFAULT_MAX_EXPANSIONS := 4000  # PLACEHOLDER
const NO_TILE := Vector2i(-1, -1)

const _KEY_MUL := 1 << 21          # heap key = f * _KEY_MUL + tile index (index < 2^21)
const _STAND_UNKNOWN := 0
const _STAND_NO := 1
const _STAND_YES := 2

var grid: WorldGrid
var clearance: int

## Total path searches / expansions / microseconds spent searching since
## creation (bench / stats).
var searches_total: int = 0
var expansions_total: int = 0
var search_usec_total: int = 0
## Expansions used by the last find_path call.
var last_expansions: int = 0
## True when the last find_path failed after exploring EVERY tile reachable
## from its start (not cut off by max_expansions): last_region() is then
## the complete reachable set of that start tile.
var last_exhausted: bool = false

var _w: int
var _h: int
var _solid_lut := PackedByteArray()   # tile id -> 1 if solid
var _stand := PackedByteArray()       # per tile: _STAND_*
var _g := PackedInt32Array()
var _open := PackedInt32Array()       # search stamp when the tile was opened
var _closed := PackedInt32Array()     # search stamp when the tile was closed
var _parent := PackedInt32Array()
var _stamp := 0
var _heap := PackedInt64Array()
var _heap_size := 0
var _nb := PackedInt32Array()         # neighbour scratch: dest index, cost, ...
var _closed_list := PackedInt32Array() # tiles closed by the last search
var _gx0 := 0                         # bounding box of the current goals
var _gy0 := 0
var _gx1 := 0
var _gy1 := 0
# Bound only during a public call (never kept: WorldGrid writes would copy).
var _t := PackedByteArray()
var _s := PackedByteArray()
var _budget_tick := -1
var _budget_used := 0
var _tick_expansions := 0


func _init(world_grid: WorldGrid, clearance_tiles: int = 3) -> void:
	grid = world_grid
	clearance = maxi(1, clearance_tiles)
	_w = grid.width
	_h = grid.height
	_solid_lut.resize(256)
	for id in 256:
		_solid_lut[id] = 1 if grid.registry.is_solid(id) else 0
	var n := _w * _h
	_stand.resize(n)
	_g.resize(n)
	_open.resize(n)
	_closed.resize(n)
	_parent.resize(n)
	_heap.resize(256)
	grid.tiles_changed.connect(_on_tiles_changed)


# --- Public queries -----------------------------------------------------

## True if an agent can stand with its feet at `feet`: all body tiles are
## passable and it rests on a solid tile, on a ladder, or on top of a ladder.
func can_stand(feet: Vector2i) -> bool:
	_bind()
	var ok := _stand_at(feet.x, feet.y)
	_unbind()
	return ok


## Tiles reachable in one move from a standable `feet` tile.
func neighbors(feet: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	_bind()
	if _stand_at(feet.x, feet.y):
		_neighbors(feet.x, feet.y)
		for j in range(0, _nb.size(), 2):
			out.append(Vector2i(_nb[j] % _w, _nb[j] / _w))
	_unbind()
	return out


## Ticks needed for the single move from -> to, or -1 if that move is not
## legal right now (used to validate paths step by step).
func move_cost(from: Vector2i, to: Vector2i) -> int:
	var cost := -1
	_bind()
	if _in(to.x, to.y) and _stand_at(from.x, from.y):
		_neighbors(from.x, from.y)
		var d := to.y * _w + to.x
		for j in range(0, _nb.size(), 2):
			if _nb[j] == d:
				cost = _nb[j + 1]
				break
	_unbind()
	return cost


## A* from `from` to the nearest (by cost) of `goals`. Returns the tiles to
## step through, excluding `from`; [] when no path was found within
## max_expansions. NOTE: also [] when `from` is itself a goal — callers check
## that first. Does not consume the per-tick budget (see consume_budget()).
func find_path(from: Vector2i, goals: Array[Vector2i], max_expansions: int = DEFAULT_MAX_EXPANSIONS) -> Array[Vector2i]:
	var t0 := Time.get_ticks_usec()
	var out := _search(from, goals, max_expansions)
	search_usec_total += Time.get_ticks_usec() - t0
	_tick_expansions += last_expansions
	expansions_total += last_expansions
	return out


func _search(from: Vector2i, goals: Array[Vector2i], max_expansions: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	searches_total += 1
	last_expansions = 0
	last_exhausted = false
	_closed_list.clear()
	if goals.is_empty() or not _in(from.x, from.y):
		return out
	_bind()
	if not _stand_at(from.x, from.y):
		_unbind()
		return out
	var goal_set := {}
	_gx0 = _w
	_gy0 = _h
	_gx1 = -1
	_gy1 = -1
	for gt in goals:
		if _in(gt.x, gt.y) and not goal_set.has(gt.y * _w + gt.x):
			goal_set[gt.y * _w + gt.x] = true
			_gx0 = mini(_gx0, gt.x)
			_gy0 = mini(_gy0, gt.y)
			_gx1 = maxi(_gx1, gt.x)
			_gy1 = maxi(_gy1, gt.y)
	var start := from.y * _w + from.x
	if goal_set.is_empty() or goal_set.has(start):
		_unbind()
		return out
	_stamp += 1
	_heap_size = 0
	_g[start] = 0
	_open[start] = _stamp
	_parent[start] = -1
	_heap_push(_heur(from.x, from.y) * _KEY_MUL + start)
	var expansions := 0
	var found := -1
	while _heap_size > 0:
		var cur := int(_heap_pop() % _KEY_MUL)
		if _closed[cur] == _stamp:
			continue
		_closed[cur] = _stamp
		if goal_set.has(cur):
			found = cur
			break
		expansions += 1
		if expansions > max_expansions:
			break
		_closed_list.append(cur)
		var cx := cur % _w
		var cy := cur / _w
		_neighbors(cx, cy)
		var gc := _g[cur]
		for j in range(0, _nb.size(), 2):
			var d := _nb[j]
			if _closed[d] == _stamp:
				continue
			var ng := gc + _nb[j + 1]
			if _open[d] != _stamp or ng < _g[d]:
				_open[d] = _stamp
				_g[d] = ng
				_parent[d] = cur
				_heap_push((ng + _heur(d % _w, d / _w)) * _KEY_MUL + d)
	last_expansions = expansions
	last_exhausted = found < 0 and _heap_size == 0
	if found >= 0:
		var i := found
		while i != start:
			out.append(Vector2i(i % _w, i / _w))
			i = _parent[i]
		out.reverse()
	_unbind()
	return out


## Tile indices (y * width + x) expanded by the last find_path. When
## last_exhausted is true this is every standable tile reachable from its start.
func last_region() -> PackedInt32Array:
	return _closed_list.duplicate()


# --- Per-tick search budget --------------------------------------------

## Takes one path search from this tick's shared budget. False = budget
## exhausted; the caller waits for a later tick.
## The budget also ends once this tick's searches expanded
## EXPANSION_BUDGET_PER_TICK tiles (a few long failing searches would
## otherwise make one tick very slow).
func consume_budget(tick: int) -> bool:
	if tick != _budget_tick:
		_budget_tick = tick
		_budget_used = 0
		_tick_expansions = 0
	if _budget_used >= PATH_BUDGET_PER_TICK or _tick_expansions >= EXPANSION_BUDGET_PER_TICK:
		return false
	_budget_used += 1
	return true


func budget_left(tick: int) -> int:
	if tick != _budget_tick:
		return PATH_BUDGET_PER_TICK
	if _tick_expansions >= EXPANSION_BUDGET_PER_TICK:
		return 0
	return PATH_BUDGET_PER_TICK - _budget_used


## Searches taken from the budget in `tick` (0 if that tick is not current).
func budget_used(tick: int) -> int:
	return _budget_used if tick == _budget_tick else 0


## Forget all cached standability (after changes that bypass tiles_changed).
func invalidate_all() -> void:
	_stand.fill(_STAND_UNKNOWN)


# --- Internals ----------------------------------------------------------

func _bind() -> void:
	_t = grid.tiles
	_s = grid.structures


func _unbind() -> void:
	_t = PackedByteArray()
	_s = PackedByteArray()


func _in(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < _w and y < _h


func _passable(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < _w and y < _h and _solid_lut[_t[y * _w + x]] == 0


func _solid(x: int, y: int) -> bool:
	return x < 0 or y < 0 or x >= _w or y >= _h or _solid_lut[_t[y * _w + x]] == 1


func _ladder(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < _w and y < _h and _s[y * _w + x] == WorldGrid.Structure.LADDER


func _stand_at(x: int, y: int) -> bool:
	if x < 0 or y < 0 or x >= _w or y >= _h:
		return false
	var i := y * _w + x
	var c := _stand[i]
	if c != _STAND_UNKNOWN:
		return c == _STAND_YES
	var ok := true
	for k in clearance:
		if not _passable(x, y - k):
			ok = false
			break
	if ok:
		ok = _solid(x, y + 1) or _s[i] == WorldGrid.Structure.LADDER or _ladder(x, y + 1)
	_stand[i] = _STAND_YES if ok else _STAND_NO
	return ok


## Fills _nb with (dest index, cost) pairs for a standable (x, y).
## Hot path of A*: passability is read straight from the bound arrays.
func _neighbors(x: int, y: int) -> void:
	_nb.clear()
	var w := _w
	var top := y - (clearance - 1)
	var hy := y - clearance
	var headroom := hy >= 0 and _solid_lut[_t[hy * w + x]] == 0  # for stepping up
	for side in 2:
		var nx := x - 1 if side == 0 else x + 1
		if nx < 0 or nx >= w:
			continue
		if _stand_at(nx, y):
			_nb.append(y * w + nx)
			_nb.append(TICKS_PER_STEP)
		if headroom and _stand_at(nx, y - 1):
			_nb.append((y - 1) * w + nx)
			_nb.append(TICKS_PER_STEP)
		if top < 0:
			continue
		# Side column free from head height down to the feet row...
		var i := top * w + nx
		var col_ok := true
		for yy in range(top, y + 1):
			if _solid_lut[_t[i]] == 1:
				col_ok = false
				break
			i += w
		if not col_ok:
			continue
		# ...then step down (k = 1) or drop (k = 2..MAX_DROP) while it stays free.
		var k := 1
		while k <= MAX_DROP and y + k < _h:
			if _solid_lut[_t[i]] == 1:
				break
			if _stand_at(nx, y + k):
				_nb.append(i)
				_nb.append(TICKS_PER_STEP if k == 1 else TICKS_PER_DROP_TILE * k)
			k += 1
			i += w
	var here := y * w + x
	var here_ladder := _s[here] == WorldGrid.Structure.LADDER
	if y > 0 and (here_ladder or _s[here - w] == WorldGrid.Structure.LADDER) and _stand_at(x, y - 1):
		_nb.append(here - w)
		_nb.append(TICKS_PER_LADDER_STEP)
	if y + 1 < _h and (here_ladder or _s[here + w] == WorldGrid.Structure.LADDER) and _stand_at(x, y + 1):
		_nb.append(here + w)
		_nb.append(TICKS_PER_LADDER_STEP)


## Manhattan distance to the goals' bounding box (never more than the
## distance to the nearest goal) × step cost.
func _heur(x: int, y: int) -> int:
	var dx := _gx0 - x if x < _gx0 else (x - _gx1 if x > _gx1 else 0)
	var dy := _gy0 - y if y < _gy0 else (y - _gy1 if y > _gy1 else 0)
	return (dx + dy) * TICKS_PER_STEP


func _heap_push(key: int) -> void:
	if _heap_size >= _heap.size():
		_heap.resize(_heap.size() * 2)
	var i := _heap_size
	_heap_size += 1
	while i > 0:
		var p := (i - 1) >> 1
		var pk := _heap[p]
		if pk <= key:
			break
		_heap[i] = pk
		i = p
	_heap[i] = key


func _heap_pop() -> int:
	var top := _heap[0]
	_heap_size -= 1
	if _heap_size == 0:
		return top
	var key := _heap[_heap_size]
	var i := 0
	var n := _heap_size
	while true:
		var c := 2 * i + 1
		if c >= n:
			break
		if c + 1 < n and _heap[c + 1] < _heap[c]:
			c += 1
		if _heap[c] >= key:
			break
		_heap[i] = _heap[c]
		i = c
	_heap[i] = key
	return top


func _on_tiles_changed(rect: Rect2i) -> void:
	# Tile p affects feet p-1 (its floor) and feet p .. p+(clearance-1) (body).
	var r := Rect2i(rect.position.x, rect.position.y - 1, rect.size.x,
			rect.size.y + clearance).intersection(grid.bounds())
	if not r.has_area():
		return
	if r.get_area() * 4 > _stand.size():
		invalidate_all()
		return
	for y in range(r.position.y, r.end.y):
		var row := y * _w
		for x in range(r.position.x, r.end.x):
			_stand[row + x] = _STAND_UNKNOWN
