class_name ItemStack
extends RefCounted
## One physical pile of a single material (M2 contract §3). Runtime instance
## only; owned and mutated exclusively by Inventory. Other modules read it.
## Stacks are never merged in M2: each spawn/split has its own stable id.

## Stable id from StableIdAllocator category "item" ("item:12").
var id: String = ""
## Material key = TileDef.key of the dug tile (e.g. &"dirt", &"rock").
var material: StringName = &""
## Mass in kg, always > 0 while the stack exists.
var kg: float = 0.0
## Inventory.Holder value (GROUND / NPC / SITE / CRATE).
var holder: int = 0
## Ground tile; meaningful only when holder == Inventory.Holder.GROUND.
var tile: Vector2i = Vector2i(-1, -1)
## NPC id when holder == NPC, job id when holder == SITE, building id when
## holder == CRATE, "" when GROUND.
var holder_id: String = ""


func _to_string() -> String:
	return "ItemStack(%s %s %.3fkg holder=%d tile=%s by=%s)" % [
			id, material, kg, holder, tile, holder_id]
