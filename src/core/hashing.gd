class_name Hashing
extends RefCounted
## Platform-independent content hashing (used for world determinism checks
## and save-file integrity). Never use built-in hash() for persisted values.


static func sha256_hex(data: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	if not data.is_empty():
		ctx.update(data)
	return ctx.finish().hex_encode()
