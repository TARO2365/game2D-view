class_name RigAnim
extends RefCounted
## Keyframed animations for the cut-out rig (D-027 step 3). Each animation is
## a loop of evenly spaced keys; channels are bone rotations in degrees
## ("forward" = toward the facing direction, 0 = rest pose) plus a few body
## offsets. sample() blends neighbouring keys with smoothstep easing, so the
## rig is smooth at any frame rate; the caller drives the phase from the
## ground covered (walk/carry/climb) or from time.

## Channels: <bone> = rotation (deg, forward positive); "pelvis_y" = body bob
## (px, + = down); "root_rot" = whole-body rotation (deg); "root_y" = whole
## body offset (px). Bones missing from a rig are ignored.
const ANIMS := {
	&"idle": {
		&"torso": [0.0, 1.5], &"head": [0.0, 2.5],
		&"upper_arm_f": [3.0, -1.0], &"upper_arm_b": [-3.0, 1.0],
		&"pelvis_y": [0.0, 1.0],
	},
	&"eat": {
		&"upper_arm_f": [40.0, 115.0, 40.0, 20.0], &"forearm_f": [60.0, 100.0, 60.0, 30.0],
		&"upper_arm_b": [30.0, 32.0, 30.0, 28.0], &"head": [2.0, -4.0, 2.0, 0.0],
		&"torso": [2.0, 3.0, 2.0, 1.0], &"pelvis_y": [0.0, 0.5, 0.0, 0.0],
	},
	&"walk": {
		&"thigh_f": [24.0, 0.0, -24.0, 0.0], &"thigh_b": [-24.0, 0.0, 24.0, 0.0],
		&"shin_f": [0.0, -22.0, 0.0, -6.0], &"shin_b": [0.0, -6.0, 0.0, -22.0],
		&"upper_arm_f": [-22.0, 0.0, 22.0, 0.0], &"upper_arm_b": [22.0, 0.0, -22.0, 0.0],
		&"forearm_f": [10.0, 18.0, 30.0, 18.0], &"forearm_b": [30.0, 18.0, 10.0, 18.0],
		&"torso": [3.0, 4.0, 3.0, 4.0], &"head": [-1.0, 0.0, -1.0, 0.0],
		&"pelvis_y": [0.0, -3.0, 0.0, -3.0],
	},
	&"carry": {
		&"thigh_f": [18.0, 0.0, -18.0, 0.0], &"thigh_b": [-18.0, 0.0, 18.0, 0.0],
		&"shin_f": [0.0, -18.0, 0.0, -5.0], &"shin_b": [0.0, -5.0, 0.0, -18.0],
		&"upper_arm_f": [70.0, 66.0, 70.0, 66.0], &"upper_arm_b": [76.0, 72.0, 76.0, 72.0],
		&"forearm_f": [20.0, 24.0, 20.0, 24.0], &"forearm_b": [20.0, 24.0, 20.0, 24.0],
		&"torso": [-3.0, -2.0, -3.0, -2.0],
		&"pelvis_y": [0.0, -2.0, 0.0, -2.0],
	},
	&"climb": {
		&"upper_arm_f": [165.0, 150.0, 140.0, 155.0], &"upper_arm_b": [140.0, 155.0, 165.0, 150.0],
		&"forearm_f": [0.0, 15.0, 25.0, 10.0], &"forearm_b": [25.0, 10.0, 0.0, 15.0],
		&"thigh_f": [45.0, 25.0, 0.0, 20.0], &"thigh_b": [0.0, 20.0, 45.0, 25.0],
		&"shin_f": [-50.0, -25.0, 0.0, -20.0], &"shin_b": [0.0, -20.0, -50.0, -25.0],
		&"pelvis_y": [0.0, -3.0, 0.0, -3.0],
	},
	&"dig": {
		&"upper_arm_f": [165.0, 130.0, 60.0, 25.0], &"upper_arm_b": [150.0, 120.0, 55.0, 30.0],
		&"forearm_f": [20.0, 10.0, 0.0, 0.0], &"forearm_b": [20.0, 10.0, 0.0, 0.0],
		&"torso": [-6.0, -2.0, 8.0, 14.0], &"head": [4.0, 2.0, -2.0, -4.0],
		&"thigh_f": [12.0, 12.0, 14.0, 16.0], &"thigh_b": [-10.0, -10.0, -10.0, -10.0],
		&"shin_f": [-10.0, -10.0, -14.0, -18.0],
		&"pelvis_y": [0.0, 0.0, 2.0, 4.0],
	},
	&"build": {
		&"upper_arm_f": [110.0, 75.0, 110.0, 75.0], &"upper_arm_b": [60.0, 55.0, 60.0, 55.0],
		&"forearm_f": [40.0, 10.0, 40.0, 10.0], &"forearm_b": [30.0, 30.0, 30.0, 30.0],
		&"torso": [4.0, 7.0, 4.0, 7.0],
		&"pelvis_y": [0.0, 1.0, 0.0, 1.0],
	},
	&"sleep": {
		&"root_rot": [-90.0, -90.0], &"root_y": [-26.0, -27.5],
		&"thigh_f": [40.0, 40.0], &"thigh_b": [35.0, 35.0], &"shin_f": [-55.0, -55.0], &"shin_b": [-50.0, -50.0],
		&"upper_arm_f": [60.0, 62.0], &"upper_arm_b": [50.0, 52.0], &"head": [-8.0, -6.0],
	},
	&"fall": {
		&"upper_arm_f": [160.0, 175.0], &"upper_arm_b": [150.0, 170.0],
		&"forearm_f": [-20.0, 10.0], &"forearm_b": [-10.0, 20.0],
		&"thigh_f": [20.0, -10.0], &"thigh_b": [-15.0, 15.0],
		&"head": [-6.0, -10.0],
	},
}

## Seconds per loop for time-driven animations; ground-driven ones use the
## distance the caller passes.
const LOOP_SEC := {&"idle": 3.0, &"eat": 1.6, &"dig": 0.8, &"build": 0.55, &"sleep": 3.5, &"fall": 0.5}


static func has_anim(anim: StringName) -> bool:
	return ANIMS.has(anim)


## Channel values at phase (0..1 = one loop) with eased blending.
static func sample(anim: StringName, phase: float) -> Dictionary:
	var keys: Dictionary = ANIMS.get(anim, ANIMS[&"idle"])
	var out := {}
	for ch in keys:
		var vals: Array = keys[ch]
		var n := vals.size()
		var f := fposmod(phase, 1.0) * n
		var i := floori(f)
		var t := f - i
		t = t * t * (3.0 - 2.0 * t)
		out[ch] = lerpf(float(vals[i % n]), float(vals[(i + 1) % n]), t)
	return out
