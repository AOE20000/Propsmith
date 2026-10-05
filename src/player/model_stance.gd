extends Node
class_name ModelStance
## Gives an animation-less humanoid a stance that reads as "standing" instead
## of frozen in its authored T-pose, plus a breath cycle so it is not a statue.
##
## Why this exists: a VRM arrives with expression clips and no body clip (the
## Configura body it can replace has its own `Idle`). Until a real idle is
## authored or retargeted, this component puts the arms down and animates a
## shallow breathing sway — the difference between "a character standing" and an
## unposed rig.
##
## Bone names are the **VRM 1.0 standard humanoid names** (`LeftUpperArm`, ...),
## which the importer normalises to, so this works for any conforming VRM rather
## than one particular rig. Missing bones are skipped silently.
##
## Retire this component when real clips arrive — it is a stand-in, not a system.

## Where each bone should point, in skeleton space, for the character's **left**
## side; the right side mirrors X. Measured on this rig: bones point along +Y in
## their rest pose, the character's left is **+X**, up is +Y and the face looks
## along **+Z** — the axes below are written in that frame.
##
## Aiming at an absolute direction is what makes this rig-agnostic. The previous
## version rotated the upper arm by a fixed *local* Z angle of 68°, which only
## means "arms down" on the one rig it was tuned against — on a VRM-normalised
## skeleton the same local axis is rolled differently and 68° barely lowers the
## arm. Measured on the real body, the arm stayed near horizontal.
@export var shoulder_aim: Vector3 = Vector3(1.0, -0.18, 0.0)
## Barely off vertical, a little outward, a little forward: a relaxed hang. The
## outward component has to clear the hips — this body is wider than the rig the
## old fixed-angle version was tuned on, and a garment will widen it further.
@export var upper_arm_aim: Vector3 = Vector3(0.26, -0.955, 0.05)
## The forearm leans a touch further forward, which reads as a soft elbow rather
## than a straight, pinned-down arm — but not so far that the hand floats in
## front of the thigh.
@export var forearm_aim: Vector3 = Vector3(0.16, -0.965, 0.16)
## Breathing: chest scale amplitude and cycle speed.
@export var breath_amount: float = 0.012
@export var breath_speed: float = 1.6
## Head sway amplitude (degrees) and speed — a slow idle drift.
@export var sway_degrees: float = 1.1
@export var sway_speed: float = 0.55
## 按需更新：skeletons farther than this from the camera stop their per-frame
## breathing/sway writes. The writes are idempotent re-applications over a
## recorded baseline, so skipping frames is invisible — a citizen at 80 m keeps
## walking (the agent moves the body) but costs zero bone writes.
@export var active_range: float = 45.0

var _skeleton: Skeleton3D = null
var _base_poses: Dictionary = {}
## bone name -> the global basis our aiming left it with. A child's orientation
## depends on where its parent ended up, so the chain has to be solved in order
## and the answers remembered.
var _applied_global: Dictionary = {}
var _phase: float = 0.0
var _frame: int = 0
var _active: bool = true


## Bind to a model root and apply the stance. Safe to call with a model that has
## no VRM-named bones (a capsule fallback, a mod model) — nothing happens.
func setup(model: Node3D) -> void:
	if model == null:
		return
	for candidate: Node in model.find_children("*", "Skeleton3D", true, false):
		_skeleton = candidate as Skeleton3D
		break
	if _skeleton == null:
		return
	_apply_arm_pose()


## Arms down for both sides. Order matters: each aim is solved against where its
## parent ended up, so shoulders go before upper arms and upper arms before
## forearms.
func _apply_arm_pose() -> void:
	_aim_pair(&"LeftShoulder", &"RightShoulder", shoulder_aim)
	_aim_pair(&"LeftUpperArm", &"RightUpperArm", upper_arm_aim)
	_aim_pair(&"LeftLowerArm", &"RightLowerArm", forearm_aim)


## Re-aim the arms from scratch. Called by `ModelClips` when a locomotion clip
## stops: the clip owned the arm poses while it played, and the aims captured
## at setup are stale after that — re-solving restores the relaxed hang.
func reapply() -> void:
	if _skeleton == null:
		return
	_apply_arm_pose()


## `aim` is written for the left side; the right side mirrors X.
func _aim_pair(left: StringName, right: StringName, aim: Vector3) -> void:
	_aim_bone(left, aim)
	_aim_bone(right, Vector3(-aim.x, aim.y, aim.z))


## Point a bone's +Y axis (Godot's head→tail direction) at `target`, a direction
## in skeleton space, by solving for the local pose that produces it.
##
## The convention this is written against, measured rather than assumed:
##   * `global_pose = parent_global_pose · pose`, and
##   * a bone's `pose` **defaults to its rest transform** — so writing an identity
##     rotation does not mean "leave the bone alone", it *erases* the rest
##     orientation. (An earlier version of this file computed the correction in
##     the bone's own rest frame and was consistently 90° out, because the arm
##     bone's rest is a 180°-about-Y rotation, not identity.)
func _aim_bone(bone_name: StringName, target: Vector3) -> void:
	if _skeleton == null:
		return
	var index := _skeleton.find_bone(bone_name)
	if index < 0:
		return
	var parent := _skeleton.get_bone_parent(index)
	var parent_global := Basis.IDENTITY
	if parent >= 0:
		var parent_name := _skeleton.get_bone_name(parent)
		parent_global = _applied_global.get(
			parent_name, _skeleton.get_bone_global_rest(parent).basis
		)
	var current := parent_global * _skeleton.get_bone_pose(index).basis
	var wanted := _safe_direction(current.y.normalized(), target.normalized())
	var correction := Basis(Quaternion(current.y.normalized(), wanted))
	# Solve  parent_global · pose_new = correction · parent_global · pose_old
	var pose := parent_global.inverse() * correction * current
	_skeleton.set_bone_pose_rotation(index, pose.get_rotation_quaternion())
	_applied_global[bone_name] = correction * current


## The shortest arc between two directions is undefined when they are exactly
## opposed; fall back to any perpendicular axis so the rotation stays well
## defined (a degenerate one would make the whole chain spin randomly).
func _safe_direction(from: Vector3, to: Vector3) -> Vector3:
	if from.dot(to) >= -0.9999:
		return to
	var helper := Vector3.RIGHT if absf(to.x) < 0.9 else Vector3.UP
	return to.cross(helper).normalized()


func _process(delta: float) -> void:
	if _skeleton == null:
		return
	# Distance gate, re-evaluated twice a second: the common case (still far,
	# still near) is one early return, not a walk of the bone list.
	_frame += 1
	if _frame % 30 == 1:
		_update_active()
	if not _active:
		return
	_phase += delta
	var breath := sin(_phase * breath_speed) * breath_amount
	_scale_bone(&"Chest", breath)
	var sway := sin(_phase * sway_speed) * deg_to_rad(sway_degrees)
	_drift_bone(&"Spine", Vector3(0.0, 0.0, sway))
	_drift_bone(&"Neck", Vector3(0.0, 0.0, -sway * 0.4))
	# Re-assert the head every frame, with no offset of its own. `ModelHeadAim`
	# composes its look-around offset on top of whatever the head holds, so a
	# pose left behind there would accumulate frame over frame; writing the
	# base back gives that component a clean substrate to multiply into.
	_drift_bone(&"Head", Vector3.ZERO)


## Camera distance decides whether this figure animates. No camera (headless
## probes, the smoke test) means nothing to cull against — stay active.
func _update_active() -> void:
	if not _skeleton.is_inside_tree():
		return
	var viewport := _skeleton.get_viewport()
	if viewport == null:
		return
	var camera := viewport.get_camera_3d()
	if camera == null:
		_active = true
		return
	_active = _skeleton.global_position.distance_to(camera.global_position) <= active_range


## Breathing lives on the chest bone's scale — invisible in the silhouette but
## reads as life in motion.
func _scale_bone(bone_name: StringName, amount: float) -> void:
	var index := _skeleton.find_bone(bone_name)
	if index < 0:
		return
	_skeleton.set_bone_pose_scale(index, Vector3(1.0 + amount, 1.0 + amount * 1.4, 1.0 + amount))


## Re-apply a rotating offset on top of a recorded baseline, so repeated frames
## compose around the stance instead of accumulating. Bones the stance never
## aimed (the spine, the neck) have no baseline yet — capture the current pose as
## one on first use, otherwise their sway silently never happens.
func _drift_bone(bone_name: StringName, degrees: Vector3) -> void:
	var index := _skeleton.find_bone(bone_name)
	if index < 0:
		return
	if not _base_poses.has(bone_name):
		_base_poses[bone_name] = _skeleton.get_bone_pose_rotation(index)
	var base: Quaternion = _base_poses[bone_name]
	var offset := Quaternion.from_euler(Vector3(
		deg_to_rad(degrees.x), deg_to_rad(degrees.y), deg_to_rad(degrees.z)
	))
	_skeleton.set_bone_pose_rotation(index, base * offset)
