class_name WorldSlots
extends RefCounted
## Stored worlds (D-014): at most MAX_WORLDS folders under `root`, each with
## meta.json + saves. Only one world is ever loaded at a time; creating a new
## world beyond the limit is refused until the player deletes one.

const MAX_WORLDS := 3
const NAME_MAX_LEN := 32
const META_FILE := "meta.json"
const DEFAULT_ROOT := "user://worlds"

var root: String
var registry: TileRegistry


func _init(reg: TileRegistry, root_dir: String = DEFAULT_ROOT) -> void:
	registry = reg
	root = root_dir
	DirAccess.make_dir_recursive_absolute(root)


func world_dir(id: String) -> String:
	return root.path_join(id)


## Metas sorted by last played, newest first.
func list_worlds() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var d := DirAccess.open(root)
	if d == null:
		return out
	for sub in d.get_directories():
		var m := read_meta(sub)
		if not m.is_empty():
			out.append(m)
	out.sort_custom(func(a, b): return float(a["last_played_unix"]) > float(b["last_played_unix"]))
	return out


func count() -> int:
	return list_worlds().size()


func can_create() -> bool:
	return count() < MAX_WORLDS


func validate_name(world_name: String) -> CommandResult:
	var n := world_name.strip_edges()
	if n.is_empty():
		return CommandResult.failure(&"name_required", "Please enter a world name")
	if n.length() > NAME_MAX_LEN:
		return CommandResult.failure(&"name_too_long", "Name must be %d characters or fewer" % NAME_MAX_LEN)
	for m in list_worlds():
		if String(m["name"]).to_lower() == n.to_lower():
			return CommandResult.failure(&"name_taken", "A world named \"%s\" already exists" % n)
	return CommandResult.success({"name": n})


func suggest_name() -> String:
	var taken := {}
	for m in list_worlds():
		taken[String(m["name"]).to_lower()] = true
	var i := 1
	while taken.has("world %d" % i):
		i += 1
	return "World %d" % i


func create_world(world_name: String, world_seed: int, preset: StringName) -> CommandResult:
	if not can_create():
		return CommandResult.failure(&"world_limit",
				"You already have %d worlds. Delete one to create a new world." % MAX_WORLDS)
	var v := validate_name(world_name)
	if not v.ok:
		return v
	if not WorldGenerator.PRESETS.has(preset):
		return CommandResult.failure(&"invalid_preset", "Unknown world size")
	var id := _new_id()
	DirAccess.make_dir_recursive_absolute(world_dir(id))
	var now := Time.get_unix_time_from_system()
	var meta := {
		"id": id, "name": v.data["name"], "seed": world_seed, "preset": String(preset),
		"size": WorldGenerator.PRESETS[preset], "gen_version": WorldGenerator.GEN_VERSION,
		"created_unix": now, "last_played_unix": now,
	}
	var session := WorldSession.create_new(meta, registry)
	var w := write_meta(meta)
	if not w.ok:
		return w
	var sv := SaveService.save(session, world_dir(id), SaveService.Kind.MANUAL)
	if not sv.ok:
		return sv
	return CommandResult.success({"session": session, "id": id})


func load_world(id: String) -> CommandResult:
	var meta := read_meta(id)
	if meta.is_empty():
		return CommandResult.failure(&"unknown_world", "World not found")
	var r := SaveService.load_world(world_dir(id), registry, meta)
	if r.ok:
		var s: WorldSession = r.data["session"]
		s.meta["last_played_unix"] = Time.get_unix_time_from_system()
		write_meta(s.meta)
	return r


func delete_world(id: String) -> CommandResult:
	if not _is_safe_id(id) or not DirAccess.dir_exists_absolute(world_dir(id)):
		return CommandResult.failure(&"unknown_world", "World not found")
	var dir := world_dir(id)
	var d := DirAccess.open(dir)
	for f in d.get_files():
		DirAccess.remove_absolute(dir.path_join(f))
	var e := DirAccess.remove_absolute(dir)
	if e != OK:
		return CommandResult.failure(&"delete_failed", "Could not delete world (%s)" % error_string(e))
	return CommandResult.success({"id": id})


func write_meta(meta: Dictionary) -> CommandResult:
	var out := meta.duplicate()
	var size: Vector2i = meta["size"]
	out["size"] = [size.x, size.y]
	var path := world_dir(meta["id"]).path_join(META_FILE)
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return CommandResult.failure(&"write_failed", "Cannot write world info")
	f.store_string(JSON.stringify(out, "  "))
	f.close()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var e := DirAccess.rename_absolute(tmp, path)
	if e != OK:
		return CommandResult.failure(&"write_failed", "Cannot finalize world info (%s)" % error_string(e))
	return CommandResult.success()


func read_meta(id: String) -> Dictionary:
	if not _is_safe_id(id):
		return {}
	var path := world_dir(id).path_join(META_FILE)
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	for k in ["id", "name", "seed", "size", "created_unix", "last_played_unix"]:
		if not parsed.has(k):
			return {}
	var size_a: Variant = parsed["size"]
	if typeof(size_a) != TYPE_ARRAY or size_a.size() != 2:
		return {}
	parsed["size"] = Vector2i(int(size_a[0]), int(size_a[1]))
	parsed["seed"] = int(parsed["seed"])
	parsed["gen_version"] = int(parsed.get("gen_version", 0))
	return parsed


func _new_id() -> String:
	var n := int(Time.get_unix_time_from_system() * 1000.0)
	while DirAccess.dir_exists_absolute(world_dir("w%d" % n)):
		n += 1
	return "w%d" % n


static func _is_safe_id(id: String) -> bool:
	return id.length() > 1 and id.begins_with("w") and id.substr(1).is_valid_int()
