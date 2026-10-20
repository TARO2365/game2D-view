class_name NpcLayer
extends Node2D
## Keeps one NpcView per colonist in sync with Colony (spawn / load) and
## marks the selected NPC. Presentation only.

var colony: Colony
var inventory: Inventory
var registry: TileRegistry
var tile_px := 64
var selected_id := ""

var _views: Dictionary = {}  # npc id -> NpcView
var _dirty := true


func setup(c: Colony, inv: Inventory, reg: TileRegistry, px: int) -> void:
	colony = c
	inventory = inv
	registry = reg
	tile_px = px
	colony.npcs_changed.connect(func() -> void: _dirty = true)


func _ready() -> void:
	sync_views()


func _process(_delta: float) -> void:
	if _dirty or _views.size() != colony.count():
		sync_views()


func sync_views() -> void:
	_dirty = false
	var alive: Dictionary = {}
	for n in colony.all_npcs():
		alive[n.id] = true
		if not _views.has(n.id):
			var v := NpcView.new()
			v.name = "Npc_%s" % n.id.replace(":", "_")
			v.setup(n, inventory, registry, tile_px)
			add_child(v)
			v.selected = n.id == selected_id
			_views[n.id] = v
	for id in _views.keys():
		if not alive.has(id):
			var gone: NpcView = _views[id]
			_views.erase(id)
			gone.queue_free()


func set_selected(npc_id: String) -> void:
	selected_id = npc_id
	for id in _views:
		(_views[id] as NpcView).selected = id == npc_id


func view_count() -> int:
	return _views.size()


func get_view(npc_id: String) -> NpcView:
	return _views.get(npc_id)
