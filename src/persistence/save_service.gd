class_name SaveService
extends RefCounted
## Saves/loads one world folder (D-007, D-016).
## Write: tmp file -> read back and verify checksum -> rotate previous file to
## .bak -> rename tmp into place, so a crash mid-write never destroys the last
## good save. Load: newest valid of manual/autosave, then .bak copies.
## Only chunks changed since generation are stored; the rest is regenerated
## from seed + GEN_VERSION and verified against the stored world hash.

enum Kind { MANUAL, AUTO }

const SAVE_VERSION := 1
const MAGIC := "LAST_BUNKER_SAVE"
const FILE_NAMES := {Kind.MANUAL: "manual.save", Kind.AUTO: "autosave.save"}
const BAK_SUFFIX := ".bak"
const TMP_SUFFIX := ".tmp"
## Godot compressed-file header; checked before opening to reject junk early.
const COMPRESSED_HEADER := "GCPF"


static func save(session: WorldSession, dir: String, kind: Kind) -> CommandResult:
	var t0 := Time.get_ticks_usec()
	var payload := build_payload(session)
	payload["kind"] = int(kind)
	var r := write_atomic(dir.path_join(FILE_NAMES[kind]), payload)
	if r.ok:
		r.data["ms"] = (Time.get_ticks_usec() - t0) / 1000.0
	return r


static func build_payload(session: WorldSession) -> Dictionary:
	var grid := session.grid
	var chunks := {}
	for i in grid.modified_chunks():
		chunks[i] = grid.get_chunk_bytes(grid.chunk_coords_of_index(i))
	return {
		"save_version": SAVE_VERSION,
		"gen_version": WorldGenerator.GEN_VERSION,
		"seed": int(session.meta["seed"]),
		"size": grid.get_size(),
		"saved_unix": Time.get_unix_time_from_system(),
		"clock": session.clock.to_snapshot(),
		"ids": session.ids.to_snapshot(),
		"chunks": chunks,
		"designations": session.designations.to_snapshot(),
		"world_hash": grid.world_hash(),
	}


static func write_atomic(path: String, payload: Dictionary) -> CommandResult:
	var data := var_to_bytes(payload)
	var envelope := {"magic": MAGIC, "save_version": SAVE_VERSION,
			"sha256": Hashing.sha256_hex(data), "data": data}
	var tmp := path + TMP_SUFFIX
	var f := FileAccess.open_compressed(tmp, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	if f == null:
		return CommandResult.failure(&"write_failed",
				"Cannot write %s (%s)" % [tmp, error_string(FileAccess.get_open_error())])
	f.store_var(envelope)
	f.close()
	var check := read_file(tmp)
	if not check["ok"]:
		DirAccess.remove_absolute(tmp)
		return CommandResult.failure(&"verify_failed", "Save verification failed: %s" % check["error"])
	if FileAccess.file_exists(path):
		var bak := path + BAK_SUFFIX
		if FileAccess.file_exists(bak):
			DirAccess.remove_absolute(bak)
		var e := DirAccess.rename_absolute(path, bak)
		if e != OK:
			return CommandResult.failure(&"rotate_failed", "Cannot keep backup (%s)" % error_string(e))
	var e2 := DirAccess.rename_absolute(tmp, path)
	if e2 != OK:
		return CommandResult.failure(&"rename_failed", "Cannot finalize save (%s)" % error_string(e2))
	return CommandResult.success({"path": path, "bytes": _file_size(path)})


## Returns {"ok": bool, "payload": Dictionary, "error": String}.
static func read_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "error": "missing"}
	var raw := FileAccess.open(path, FileAccess.READ)
	if raw == null or raw.get_length() < 4:
		return {"ok": false, "error": "unreadable or empty"}
	var header := raw.get_buffer(4).get_string_from_ascii()
	raw.close()
	if header != COMPRESSED_HEADER:
		return {"ok": false, "error": "not a save file"}
	var f := FileAccess.open_compressed(path, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	if f == null:
		return {"ok": false, "error": "cannot decompress"}
	var env: Variant = f.get_var()
	f.close()
	if typeof(env) != TYPE_DICTIONARY or env.get("magic") != MAGIC:
		return {"ok": false, "error": "bad header"}
	var data: Variant = env.get("data")
	if typeof(data) != TYPE_PACKED_BYTE_ARRAY or Hashing.sha256_hex(data) != env.get("sha256"):
		return {"ok": false, "error": "checksum mismatch"}
	var payload: Variant = bytes_to_var(data)
	if typeof(payload) != TYPE_DICTIONARY:
		return {"ok": false, "error": "bad payload"}
	return {"ok": true, "payload": payload, "error": ""}


## Loads the newest valid save in `dir`. meta supplies id/name/etc.
static func load_world(dir: String, registry: TileRegistry, meta: Dictionary) -> CommandResult:
	var errors: Array[String] = []
	var primary := _read_candidates(dir, "", errors)
	var backups := _read_candidates(dir, BAK_SUFFIX, errors)
	var first := true
	for cand in primary + backups:
		var r := session_from_payload(cand["payload"], meta, registry)
		if r.ok:
			r.data["source"] = cand["name"]
			r.data["fell_back"] = not first or String(cand["name"]).ends_with(BAK_SUFFIX) or not errors.is_empty()
			r.data["errors"] = errors
			return r
		errors.append("%s: %s" % [cand["name"], r.message])
		first = false
	return CommandResult.failure(&"no_valid_save", "No valid save found", {"errors": errors})


static func session_from_payload(p: Dictionary, meta: Dictionary, registry: TileRegistry) -> CommandResult:
	if int(p.get("save_version", -1)) != SAVE_VERSION:
		return CommandResult.failure(&"unsupported_version",
				"Unsupported save version %s" % p.get("save_version"))
	var gen := int(p.get("gen_version", -1))
	if gen != WorldGenerator.GEN_VERSION:
		return CommandResult.failure(&"gen_version_mismatch",
				"Saved with world generator v%d; this build has v%d" % [gen, WorldGenerator.GEN_VERSION])
	var size_v: Variant = p.get("size")
	if typeof(size_v) != TYPE_VECTOR2I or size_v.x <= 0 or size_v.y <= 0:
		return CommandResult.failure(&"corrupt", "Invalid world size")
	var s := WorldSession.new()
	s.meta = meta.duplicate()
	s.meta["seed"] = int(p.get("seed", 0))
	s.meta["size"] = size_v
	s.grid = WorldGenerator.generate(s.meta["seed"], size_v, registry)
	var chunks: Variant = p.get("chunks", {})
	if typeof(chunks) != TYPE_DICTIONARY:
		return CommandResult.failure(&"corrupt", "Invalid chunk data")
	for idx in chunks:
		var bytes: Variant = chunks[idx]
		if typeof(bytes) != TYPE_PACKED_BYTE_ARRAY \
				or not s.grid.set_chunk_bytes(s.grid.chunk_coords_of_index(int(idx)), bytes):
			return CommandResult.failure(&"corrupt", "Invalid chunk %s" % idx)
	if s.grid.world_hash() != p.get("world_hash"):
		return CommandResult.failure(&"integrity", "World data does not match its checksum")
	s.clock.load_snapshot(p.get("clock", {}))
	s.ids.load_snapshot(p.get("ids", {}))
	s.designations = DesignationMap.new(s.grid)
	var dropped := s.designations.load_snapshot(p.get("designations", {}))
	return CommandResult.success({"session": s, "dropped_designations": dropped})


static func _read_candidates(dir: String, suffix: String, errors: Array[String]) -> Array:
	var out := []
	for kind in FILE_NAMES:
		var name: String = FILE_NAMES[kind] + suffix
		var path := dir.path_join(name)
		if not FileAccess.file_exists(path):
			continue
		var r := read_file(path)
		if r["ok"]:
			out.append({"name": name, "payload": r["payload"]})
		else:
			errors.append("%s: %s" % [name, r["error"]])
	out.sort_custom(func(a, b): return float(a["payload"].get("saved_unix", 0)) > float(b["payload"].get("saved_unix", 0)))
	return out


static func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_length() if f else -1
