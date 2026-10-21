class_name RigFigure
extends Node2D
## Cut-out rig instance (D-027 step 3): one Sprite2D per part, all direct
## children in back-to-front order (no z_index, so the NPC never sorts behind
## terrain). Bone transforms are composed in GDScript from RigAnim channels
## and written to the sprites — no redraws, no per-frame image work.
## Origin = feet bottom-centre (cell space, 1 unit = 1 px at 64 px tiles).

var def: RigDef
var _nodes: Dictionary = {}   # bone -> CanvasItem (Sprite2D, or Part for prop/carry)
var _bones: Array[StringName] = []  # bones in parent-first order
var _head: Sprite2D
var _head_region := Rect2()
var _carry: ProcFigure.Part


func setup(d: RigDef) -> void:
	def = d
	for name in RigDef.ORDER:
		var node: Node2D = null
		if d.has_part(name):
			var s := Sprite2D.new()
			s.texture = d.atlas
			s.region_enabled = true
			var p: Dictionary = d.parts[name]
			s.region_rect = p.region
			s.centered = false
			s.offset = -(p.pivot as Vector2)
			node = s
			if name == &"head":
				_head = s
				_head_region = p.region
		elif name == &"prop":
			var pick := ProcFigure.Part.new()
			pick.painter = func(ci: CanvasItem) -> void: ProcFigure._pickaxe(ci)
			pick.position = Vector2.ZERO
			node = pick
		elif name == &"carry":
			_carry = ProcFigure.Part.new()
			_carry.painter = func(ci: ProcFigure.Part) -> void: ProcFigure.draw_chunk(ci, Vector2.ZERO, 14.0, ci.tint, 7)
			node = _carry
		if node:
			node.name = String(name)
			add_child(node)
			_nodes[name] = node
	# Parent-first evaluation order.
	var pending: Array = RigDef.PARENT.keys()
	var done := {&"": true}
	while not pending.is_empty():
		var progressed := false
		for b in pending.duplicate():
			var par := def.parent_of(b)
			if done.has(par):
				_bones.append(b)
				done[b] = true
				pending.erase(b)
				progressed = true
		if not progressed:
			break
	apply(&"idle", 0.0, false, ProcFigure.NO_CARRY)


## Poses the rig: anim at phase (0..1), eyes closed when blink, carried
## chunk colour (alpha 0 = nothing carried).
func apply(anim: StringName, phase: float, blink: bool, carry: Color) -> void:
	var ch := RigAnim.sample(anim, phase)
	var xf := {&"": Transform2D(deg_to_rad(float(ch.get(&"root_rot", 0.0))), Vector2(0, float(ch.get(&"root_y", 0.0))))}
	for b in _bones:
		var par := def.parent_of(b)
		var off := def.rest_offset(b)
		if b == &"pelvis":
			off.y += float(ch.get(&"pelvis_y", 0.0))
		# Forward swing (+deg) moves a hanging limb toward +x: negative rotation.
		var rot := -deg_to_rad(float(ch.get(b, 0.0)))
		var t: Transform2D = (xf.get(par, xf[&""]) as Transform2D) * Transform2D(rot, off)
		xf[b] = t
		var node: Node2D = _nodes.get(b)
		if node:
			node.transform = t
	if _head and def.head_blink.size.x > 0.0:
		_head.region_rect = def.head_blink if blink else _head_region
	var prop: Node2D = _nodes.get(&"prop")
	if prop:
		prop.visible = anim == &"dig" or anim == &"build"
		if not def.has_part(&"hand_f") and def.has_part(&"upper_arm_f"):
			# Pilot (one-piece arm): hold the tool at the end of the arm.
			var arm: Transform2D = xf[&"upper_arm_f"]
			var arm_len := (def.parts[&"upper_arm_f"].region as Rect2).size.y - (def.parts[&"upper_arm_f"].pivot as Vector2).y - 4.0
			prop.transform = arm * Transform2D(0.0, Vector2(0, arm_len - ProcFigure.ARM_LEN))
	if _carry:
		_carry.visible = anim == &"carry" and carry.a > 0.0
		if _carry.visible:
			_carry.tint = carry
