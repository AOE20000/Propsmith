extends Node
class_name ModelSpringBones
## Secondary motion for sway bone chains — the ahoge today, hair or skirt
## chains the moment the model grows them.
##
## The VRM addon ships a full spring-bone runtime (`VRMSecondary`), but it is
## fed by importer metadata, and this model carries none: the glTF has no
## `VRMC_springBone` extension and the skeleton has exactly one chain-shaped
## bone run (`hair_ahoge_root → ahoge.001..004`, probed by
## `tools/spring_bone_probe.tscn`). Rather than hand-assembling addon
## resources, this is the same algorithm in miniature, as a plain component:
##
##   * One **Verlet point per joint** — the joint's tail (where its child, or
##     an extrapolated tip, sits in world space). Inertia is implicit: when the
##     figure moves, the bone origin moves with it while the point lags, and
##     the difference is the follow-through the twelfth animation principle
##     asks for.
##   * **Fixed substeps** (accumulator, capped) — Verlet with a raw frame
##     delta explodes on hitches and takes the hair with it.
##   * **Chained same-frame composition**: the bone outside the chain is read
##     once per step via `get_bone_global_pose`, and every joint's global
##     transform after that is *multiplied forward locally* — the exact lesson
##     the foot IK paid for (its stale `_applied_global` cache was the whole
##     drift bug). No engine re-reads, no stale caches, N flops per joint.
##   * **Angle clamp** against the rest direction, so a teleport or a yank
##     bends the chain at most `max_degrees` instead of folding it through the
##     head, and the tail length is re-anchored every step, so the chain can
##     stretch, only swing.
##
## Writes `set_bone_pose_rotation` only. No clip animates these bones (the
## locomotion retarget covers the humanoid set), so this is the sole writer of
## the chain's pose — no substrate composition needed, unlike `ModelLean`.
## The distance gate mirrors `ModelStance.active_range`: far figures freeze
## their chain (invisible at that range) instead of simulating it.

## Skeleton bones that start sway chains. Chains are collected depth-first
## below each named root, so a forked skirt column works the same as the
## single ahoge strand. A root that does not exist is skipped silently —
## a model with no sway bones simply gets no component work.
@export var root_bones: PackedStringArray = ["hair_ahoge_root"]
## Restoring acceleration per unit of tail displacement (1/s²). Higher is a
## stiffer chain that snaps back; lower is lazy, floaty hair.
@export var stiffness: float = 450.0
## Fraction of the point's velocity removed per substep (air drag).
@export var drag: float = 0.28
## Downward acceleration scale. An ahoge grows upward, so a light gravity
## lets it sag a little past vertical instead of hanging straight down.
@export var gravity_power: float = 0.35
## Hard limit on how far the tail may swing from its rest direction.
@export var max_degrees: float = 55.0
## Beyond this distance from the camera the chain freezes (reset to rest).
@export var active_range: float = 45.0
## Fixed simulation rate. 90 Hz keeps the integrated response identical
## across 60/120/144 Hz displays.
@export var substep_hz: float = 90.0

const GRAVITY: Vector3 = Vector3(0.0, -9.8, 0.0)
## A tail point may never move further than this per substep, as a fraction
## of its chain length — the teleport guard.
const MAX_STEP_LENGTHS: float = 3.0
## How far the tail may stray from its rest-tail position, as a fraction of
## the chain length — the stretch guard that replaces pinning. Pinning the
## point to `origin + dir * len` (the first draft) silently carried the bone
## origin's translation into the tail, which is exactly the inertia the
## simulation exists to produce: the probe measured zero follow-through.
const MAX_STRETCH_LENGTHS: float = 1.5
const MAX_SUBSTEPS: int = 4


class Joint:
	extends RefCounted
	var bone: int = -1
	## The bone's origin in its parent's local space (spring-time constant:
	## a rotation-only spring never moves the origin).
	var origin_local: Vector3 = Vector3.ZERO
	## The bone's rest rotation in its parent's local space.
	var rest_rotation: Quaternion = Quaternion.IDENTITY
	## Tail offset in the bone's own local space: the child bone's rest
	## origin, or — for a leaf — the parent-to-bone direction extrapolated.
	var offset_local: Vector3 = Vector3.ZERO
	var rest_length: float = 0.0
	## Verlet state, world space.
	var point: Vector3 = Vector3.ZERO
	var prev_point: Vector3 = Vector3.ZERO


var _model: Node3D = null
var _skeleton: Skeleton3D = null
var _joints: Array[Joint] = []
var _chain_parent: int = -1
var _accumulator: float = 0.0
var _active: bool = false


func setup(model: Node3D) -> void:
	_model = model
	if model == null:
		return
	for candidate: Node in model.find_children("*", "Skeleton3D", true, false):
		_skeleton = candidate as Skeleton3D
		break
	if _skeleton == null:
		return
	for root_name: String in root_bones:
		var root: int = _skeleton.find_bone(root_name)
		if root >= 0:
			_collect_chain(root)
	if _joints.is_empty():
		_skeleton = null
		return
	for joint: Joint in _joints:
		_measure_joint(joint)
	_chain_parent = _skeleton.get_bone_parent(_joints[0].bone)
	reset_points()
	set_process(true)


## Collect a chain depth-first below `bone`, root first, so every joint is
## measured and simulated after its parent.
func _collect_chain(bone: int) -> void:
	var joint := Joint.new()
	joint.bone = bone
	_joints.append(joint)
	for child: int in _skeleton.get_bone_children(bone):
		_collect_chain(child)


## Rest-time geometry for one joint. Bone *lengths* come from neighbouring
## bone-origin distances — `rest.basis.y.length()` is 1.0 for every bone in a
## normalized rig and would silently produce a zero-length chain.
func _measure_joint(joint: Joint) -> void:
	var rest: Transform3D = _skeleton.get_bone_rest(joint.bone)
	joint.origin_local = rest.origin
	joint.rest_rotation = rest.basis.get_rotation_quaternion()
	var children := _skeleton.get_bone_children(joint.bone)
	if not children.is_empty():
		joint.offset_local = _skeleton.get_bone_rest(children[0]).origin
		joint.rest_length = joint.offset_local.length()
	else:
		# Leaf: extrapolate the parent-to-bone direction. The direction must
		# be built in *global rest* space and carried back into the bone's
		# own frame — `get_bone_rest(bone).origin` lives in the parent's
		# local space, and using it as the leaf's own offset would inherit
		# whatever twist the parent chain has.
		var parent: int = _skeleton.get_bone_parent(joint.bone)
		var own: Transform3D = _skeleton.get_bone_global_rest(joint.bone)
		if parent >= 0:
			var parent_global: Transform3D = _skeleton.get_bone_global_rest(parent)
			var direction: Vector3 = own.origin - parent_global.origin
			var length: float = direction.length()
			var local_dir: Vector3 = (own.basis.inverse() * direction).normalized()
			joint.offset_local = local_dir * maxf(length, 0.05)
			joint.rest_length = maxf(length, 0.05)
		else:
			joint.offset_local = own.basis.y * 0.07
			joint.rest_length = 0.07


## Park every Verlet point on its rest tail — the neutral state the springs
## relax into, and the state a frozen (out-of-range) chain is reset to.
func reset_points() -> void:
	var parent_global := _chain_parent_global()
	var cursor := parent_global
	for joint: Joint in _joints:
		var rest_global := cursor * Transform3D(Basis(joint.rest_rotation), joint.origin_local)
		var tail: Vector3 = rest_global * joint.offset_local
		joint.point = tail
		joint.prev_point = tail
		cursor = rest_global
	_accumulator = 0.0


func _chain_parent_global() -> Transform3D:
	# `get_bone_global_pose` is relative to the Skeleton3D node — probed:
	# moving the model root +1 m changes it by exactly 0.000. The node's own
	# transform must be carried in explicitly, or a moving figure drags its
	# whole chain inside a space that never sees the movement, and every
	# world-space Verlet point decouples from the bones. (The same trap is
	# the prime suspect for the foot IK's per-frame drift: its pinned feet
	# live in this space too.)
	if _chain_parent >= 0:
		return _skeleton.global_transform * _skeleton.get_bone_global_pose(_chain_parent)
	return _skeleton.global_transform


func _process(delta: float) -> void:
	if _skeleton == null or _model == null or not _model.is_inside_tree():
		return
	var camera := get_viewport().get_camera_3d()
	if camera != null:
		var distance: float = camera.global_position.distance_to(_model.global_position)
		if distance > active_range:
			if _active:
				_active = false
				reset_points()
			return
	_active = true
	# A hitch must not become a hair explosion: clamp the frame, cap the
	# substep debt, and throw away anything past the cap.
	advance(minf(delta, 0.05))


## Advance the simulation by `delta` seconds of fixed substeps. Public so the
## probes can drive it deterministically without a viewport.
func advance(delta: float) -> void:
	var dt := 1.0 / maxf(substep_hz, 1.0)
	_accumulator += delta
	var steps := 0
	while _accumulator >= dt and steps < MAX_SUBSTEPS:
		_step(dt)
		_accumulator -= dt
		steps += 1
	if steps == MAX_SUBSTEPS:
		_accumulator = 0.0


func _step(dt: float) -> void:
	var dt2 := dt * dt
	var parent_global := _chain_parent_global()
	var cursor := parent_global
	for joint: Joint in _joints:
		# Where the tail would sit if the bone held its rest rotation — the
		# spring's anchor — and where the bone origin is right now.
		var rest_global := cursor * Transform3D(Basis(joint.rest_rotation), joint.origin_local)
		var rest_tail: Vector3 = rest_global * joint.offset_local
		var origin_world: Vector3 = cursor * joint.origin_local

		# Verlet: the point integrates FREELY — inertia is the previous
		# step's displacement, damped. The bone origin moves with the figure;
		# the point does not follow it until the spring drags it there, and
		# that lag is the whole effect.
		var velocity := (joint.point - joint.prev_point) * (1.0 - drag)
		var max_step := joint.rest_length * MAX_STEP_LENGTHS
		if velocity.length() > max_step:
			velocity = velocity.normalized() * max_step
		var acceleration := (rest_tail - joint.point) * stiffness + GRAVITY * gravity_power
		var new_point := joint.point + velocity + acceleration * dt2

		# Stretch guard: the tail orbits its rest tail, it does not fly away.
		var straying := new_point - rest_tail
		var max_stray := joint.rest_length * MAX_STRETCH_LENGTHS
		if straying.length() > max_stray:
			new_point = rest_tail + straying.normalized() * max_stray
		joint.prev_point = joint.point
		joint.point = new_point

		# Aim the bone at the tail, with the swing direction (not the point
		# itself) clamped against the rest direction — a teleport can drag
		# the free point anywhere, the bone must never fold through the head.
		var rest_dir := (rest_tail - origin_world).normalized()
		var swing := new_point - origin_world
		var direction := rest_dir if swing.length() < 1e-6 else swing.normalized()
		var angle := direction.angle_to(rest_dir)
		var max_rad := deg_to_rad(max_degrees)
		if angle > max_rad:
			var axis := rest_dir.cross(direction)
			if axis.length() < 1e-6:
				axis = rest_dir.cross(Vector3.RIGHT)
				if axis.length() < 1e-6:
					axis = rest_dir.cross(Vector3.UP)
			direction = rest_dir.rotated(axis.normalized(), max_rad)

		# Carry the target direction into the parent's current frame and aim
		# the bone at it: pose rotation = (rest→target) ∘ rest rotation.
		var target_local: Vector3 = (cursor.basis.inverse() * direction).normalized()
		var rest_local := joint.offset_local.normalized()
		var pose_rotation := Quaternion(rest_local, target_local) * joint.rest_rotation
		_skeleton.set_bone_pose_rotation(joint.bone, Basis(pose_rotation))

		# Forward-compose the next joint's parent frame with the rotation we
		# just wrote — the same-frame read the engine would do lazily, done
		# here, for free, and never stale.
		cursor = cursor * Transform3D(Basis(pose_rotation), joint.origin_local)
