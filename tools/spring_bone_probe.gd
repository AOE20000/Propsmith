extends Node
## Census + numeric validation for `ModelSpringBones` on the real model.
##
## Part 1 (census): does the imported `base_female.vrm` carry VRM spring
## bones, and what sway-shaped bone runs does the skeleton hold?
## Part 2 (dynamics): with the component attached and driven manually, the
## chain tail must (a) hold still at rest, (b) lag behind a moving figure and
## converge after it stops — the follow-through — and (c) never swing past
## `max_degrees`, even across a teleport.

const MODEL_PATH: String = "res://assets/characters/base_female.vrm"


func _ready() -> void:
	var packed := load(MODEL_PATH) as PackedScene
	if packed == null:
		printerr("[spring_probe] FAIL: cannot load " + MODEL_PATH)
		get_tree().quit(1)
		return
	var model := packed.instantiate() as Node3D
	add_child(model)
	_census_bones(model)

	var spring := ModelSpringBones.new()
	model.add_child(spring)
	spring.setup(model)
	spring.set_process(false)
	if spring._joints.is_empty():
		printerr("[spring_probe] FAIL: no joints collected")
		get_tree().quit(1)
		return
	var skel: Skeleton3D = spring._skeleton
	var tip_idx: int = spring._joints[-1].bone
	print("[spring_probe] chain joints=%d tip='%s' parent='%s'" % [
		spring._joints.size(), skel.get_bone_name(tip_idx),
		skel.get_bone_name(skel.get_bone_parent(spring._joints[0].bone))])

	# Frame-of-reference check: does `get_bone_global_pose` include the
	# Skeleton3D node's own transform? Moving the model root by +1 m must
	# move the head's "global" pose by +1 m too; if it does not, the bone
	# "global" space is skeleton-local and everything world-space built on
	# it (this spring, and the foot IK before it) decouples from motion.
	var head: int = skel.find_bone("Head")
	var before_z: float = skel.get_bone_global_pose(head).origin.z
	model.position.z += 1.0
	var after_z: float = skel.get_bone_global_pose(head).origin.z
	model.position.z -= 1.0
	print("[spring_probe] frame check: head z before=%.3f after(+1m model)=%.3f delta=%.3f" % [
		before_z, after_z, after_z - before_z])

	var walk_speed := 5.2
	var dt := 1.0 / 60.0

	# Phase A — rest: the chain relaxes to (nearly) its rest tail. Gravity
	# may pull a small permanent sag; report the steady offset.
	for i: int in 40:
		spring.advance(dt)
	print("[spring_probe] A rest    offset=%.4f m (steady sag)" % _tip_offset(spring))

	# Phase B — walk away: offset should GROW while the figure moves.
	var peak := 0.0
	for i: int in 45:
		model.position.z += walk_speed * dt
		spring.advance(dt)
		peak = maxf(peak, _tip_offset(spring))
	print("[spring_probe] B moving  peak offset=%.4f m" % peak)

	# Phase C — stop: offset should decay back toward the steady sag.
	var after_stop := 0.0
	for i: int in 60:
		spring.advance(dt)
		after_stop = _tip_offset(spring)
	print("[spring_probe] C settled offset=%.4f m (should be near A)" % after_stop)

	# Phase D — teleport 10 m: no bone may fold through. The per-joint clamp
	# bounds each bone against its parent; the tip inherits the sum of every
	# ancestor's swing (whip effect), so the acceptance here is "the tip did
	# not flip past ~120°", not "≤ one clamp" — that strict per-bone bound
	# is asserted in the self test on the first chain bone.
	model.position.z += 10.0
	spring.advance(dt)
	var tip_angle_deg := rad_to_deg(_tip_aim_angle(spring))
	print("[spring_probe] D teleport tip aim=%.1f deg from rest (must stay < 120)" % tip_angle_deg)

	var ok: bool = peak > 0.05 and absf(after_stop - _steady_sag(spring)) < 0.05 \
		and tip_angle_deg < 120.0
	print("[spring_probe] verdict=", "PASS" if ok else "FAIL",
		" (moving peak > 5cm, settle back, no fold-through)")
	print("[spring_probe] done")
	get_tree().quit(0 if ok else 1)


func _tip_offset(spring: ModelSpringBones) -> float:
	var joint: ModelSpringBones.Joint = spring._joints[-1]
	var rest_tail := _rest_tail(spring, joint)
	return joint.point.distance_to(rest_tail)


## The tip's world-space aim angle from its rest direction, composed from
## the pose rotations the component wrote (not the free Verlet point).
func _tip_aim_angle(spring: ModelSpringBones) -> float:
	var joint: ModelSpringBones.Joint = spring._joints[-1]
	var rest_tail := _rest_tail(spring, joint)
	var origin := _rest_global(spring, joint).origin
	var rest_dir := (rest_tail - origin).normalized()
	var aimed := _aimed_dir(spring, joint)
	return aimed.angle_to(rest_dir)


## The world-space direction the bone aims right now, composed from the
## pose rotations the component wrote (not the free Verlet point).
func _aimed_dir(spring: ModelSpringBones, joint: ModelSpringBones.Joint) -> Vector3:
	var cursor := spring._chain_parent_global()
	for j: ModelSpringBones.Joint in spring._joints:
		var pose_rot: Quaternion = spring._skeleton.get_bone_pose_rotation(j.bone)
		var bone_global := cursor * Transform3D(Basis(pose_rot), j.origin_local)
		if j == joint:
			return (bone_global.basis * j.offset_local).normalized()
		cursor = bone_global
	return Vector3.UP


func _rest_tail(spring: ModelSpringBones, joint: ModelSpringBones.Joint) -> Vector3:
	return _rest_global(spring, joint) * joint.offset_local


func _rest_global(spring: ModelSpringBones, joint: ModelSpringBones.Joint) -> Transform3D:
	var cursor := spring._chain_parent_global()
	for j: ModelSpringBones.Joint in spring._joints:
		var rest_global := cursor * Transform3D(Basis(j.rest_rotation), j.origin_local)
		if j == joint:
			return rest_global
		cursor = rest_global
	return cursor


func _steady_sag(spring: ModelSpringBones) -> float:
	# Recompute phase A's steady offset cheaply: stiffness vs gravity balance.
	# Instead of analytics, just re-run: park, then 40 quiet steps.
	spring.reset_points()
	for i: int in 40:
		spring.advance(1.0 / 60.0)
	return _tip_offset(spring)


## Group bone names by their stem (name minus trailing digits/separators) and
## print stems that repeat 4+ times — those are chain candidates: hair strands
## and skirt columns arrive as numbered bone runs like `Hair1_01..Hair1_07`.
func _census_bones(model: Node) -> void:
	for node: Node in model.find_children("*", "Skeleton3D", true, false):
		var skel := node as Skeleton3D
		var total := skel.get_bone_count()
		print("[spring_probe] skeleton '%s' bones=%d" % [skel.name, total])
		var stems := {}
		for i: int in total:
			var bone_name := skel.get_bone_name(i)
			var stem := bone_name.rstrip("0123456789").trim_suffix("_").trim_suffix(".")
			if not stems.has(stem):
				stems[stem] = {"count": 0, "sample": bone_name}
			stems[stem]["count"] += 1
		for stem: String in stems:
			if stems[stem]["count"] >= 4:
				print("[spring_probe]   stem '%s*' x%d e.g. '%s'" % [
					stem, stems[stem]["count"], stems[stem]["sample"]])
		# Full chain dump for every sway candidate: name, parent, children —
		# the spring component needs the exact root name and chain shape.
		for i: int in total:
			var bone_name := skel.get_bone_name(i)
			if "ahoge".to_lower() not in bone_name.to_lower():
				continue
			var parent := skel.get_bone_parent(i)
			var kids := skel.get_bone_children(i)
			var parent_name := "(none)" if parent < 0 else skel.get_bone_name(parent)
			var kid_names: Array[String] = []
			for k: int in kids:
				kid_names.append(skel.get_bone_name(k))
			print("[spring_probe]   bone[%d] '%s' parent='%s' children=%s" % [
				i, bone_name, parent_name, kid_names])
