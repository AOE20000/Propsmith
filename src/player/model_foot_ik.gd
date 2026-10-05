extends Node
class_name ModelFootIK
## Plants the feet instead of letting the clip slide them.
##
## **NOT WIRED UP — one fault left, and it is not the maths of the angles.**
## Progress, so the next iteration does not repeat it:
##
## * Solved and *photographically verified*: the bend direction. The first build
##   rotated about the character's right axis and the picture showed a backwards
##   knee — thigh straight down, shin folded behind. Flipping the bend normal
##   (`-basis.x`) puts the knee back where a knee belongs. This is what the
##   visual probe (`tools/foot_ik_probe.tscn`) bought: the same sprint, same
##   camera, one frame with the IK off and one with it on.
## * Solved: the stiff leg. The chain is 0.724 m while the hip sits ~0.93 m from
##   a planted ankle, so the reach clamp pinned every leg at full extension.
##   **Pelvis compensation** (`_pelvis_prepare`) now pulls the hips toward the
##   goal by the shortfall — the standard remedy — and the measured goal distance
##   drops from 0.93 m to 0.65 m, inside the reach.
## * Solved: the fade was faster than a stride. At 12/s the weight only reached
##   0.4 inside a stance phase, so the foot was corrected by less than half of
##   what it needed. At 4/s the error fell from 0.66 m to 0.18 m.
##
## **What is left**: with the weight at 1.0 the foot still travels ~0.30 m per
## frame — the correction is being applied and the foot does not go where the
## solve says. So the remaining fault is in `_aim`'s pose arithmetic, not in the
## angles that feed it: writing `pose = parent_global⁻¹ · correction · current`
## is not producing the global rotation this file assumes. That is a *one-bone*
## question with a one-bone test — write a known rotation on a single bone,
## read the global basis back, compare — and it should be settled by a
## self-test rather than by more end-to-end probing. Do that first.
##
## Also worth knowing on this rig:
##   * Bone length is the distance between adjacent bone origins. The rest
##     transform's Y axis is **not** it — Godot stores rest rotations without
##     scale, so `get_bone_global_rest(x).basis.y.length()` reads 1.0 for every
##     bone.
##   * The law-of-cosines hip angle is only the right rotation when the leg is
##     already straight; an animated leg needs its current direction swung onto
##     the wanted one, thigh then shin, each measured after the previous lands.
##
## Kept and still useful: the measurement harness (planted drift, solve error,
## chain lengths, ground clearance — all per side), the hysteresis phase test,
## and the visual probe that made the two solved items visible.

## The VRM 1.0 humanoid names, which the importer normalises to (the same
## convention `ModelStance` uses for the arms).
const UPPER: StringName = &"UpperLeg"
const LOWER: StringName = &"LowerLeg"
const FOOT: StringName = &"Foot"
const SIDES: Array[String] = ["Left", "Right"]
## How high the ankle sits above the sole. The plant test measures the ankle, so
## without this a foot resting flat on the ground reads as *hovering* by its own
## ankle height and never gets planted.
const ANKLE_HEIGHT: float = 0.085
## The pelvis bone — the one bone this component is allowed to move for its own
## reasons (see `_pelvis_prepare`).
const HIPS_BONE: StringName = &"Hips"

## How far below the foot a ground ray reaches, and how far above its start it
## begins (the foot is often slightly inside the ground on a slope).
@export var ray_up: float = 0.25
@export var ray_down: float = 0.55
## Clearance at which a foot counts as having landed, and the larger clearance
## at which it is released again. The gap between them is hysteresis, and it is
## not a nicety: with a single threshold the plant flag chatters whenever a foot
## skims the value, and every re-plant re-pins the foot where it currently is —
## which is no pin at all. Measured clearances while sprinting run 0.06–0.13 m
## in stance and 0.2–0.4 m in swing, so the thresholds sit in those gaps.
@export var plant_enter: float = 0.11
@export var plant_exit: float = 0.22
## After this long standing still the foot is handed back to the clip, so a
## character that stops does not keep correcting a pose the animation owns.
@export var plant_max_time: float = 0.45
## How fast the correction fades in and out (per second) — a hard switch would
## pop. This has to be slower than a stride: at 12/s the weight only reached
## 0.4 within a stance phase, so the foot was corrected by less than half of
## what it needed and still slid.
@export var blend_speed: float = 4.0
## Skeletons farther than this from the camera stop per-frame IK, like the
## stance's distance gate.
@export var active_range: float = 45.0
## Ceiling on how far the pelvis may be pulled down in one frame (m). The real
## shortfall on this rig is ~0.2 m; the cap is there so a bad frame cannot
## drop the figure through the floor.
@export var max_pelvis_drop: float = 0.3

var _skeleton: Skeleton3D = null
var _model: Node3D = null
## Per side: the three bone indices, or an empty dictionary when the rig has no
## legs of that side.
var _chains: Array[Dictionary] = [{}, {}]
## Per side: planted flag, the world point the foot is pinned to, how long it has
## been planted, and the current correction weight.
var _planted: Array[bool] = [false, false]
var _plant_pos: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _plant_time: Array[float] = [0.0, 0.0]
var _weight: Array[float] = [0.0, 0.0]
## Last measured foot height over the ground, per side (probe diagnostics).
var _clearance: Array[float] = [0.0, 0.0]
## Whether the ground ray found anything at all, per side.
var _grounded: Array[bool] = [false, false]
## How far the foot ended up from where the solve asked for (probe diagnostics).
var _ik_error: Array[float] = [0.0, 0.0]
## (thigh length, shin length, hip→target distance) from the last solve.
var _last_reach: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
## bone name -> the global basis this component last wrote, for the chain solve.
var _applied_global: Dictionary = {}


## Bind to a model root. A model without VRM-named leg bones (a capsule, a mod
## model) simply never plants.
func setup(model: Node3D) -> void:
	_model = model
	if model == null:
		return
	for candidate: Node in model.find_children("*", "Skeleton3D", true, false):
		_skeleton = candidate as Skeleton3D
		break
	if _skeleton == null:
		return
	for i: int in SIDES.size():
		_chains[i] = {
			"upper": _skeleton.find_bone(StringName("%s%s" % [SIDES[i], UPPER])),
			"lower": _skeleton.find_bone(StringName("%s%s" % [SIDES[i], LOWER])),
			"foot": _skeleton.find_bone(StringName("%s%s" % [SIDES[i], FOOT])),
		}
	set_process(true)


func _process(delta: float) -> void:
	if _skeleton == null or _model == null or not _model.is_inside_tree():
		return
	if not _near_camera():
		set_process(false)
		return
	_pelvis_prepare()
	for i: int in SIDES.size():
		_process_foot(i, delta)


## Drop the pelvis once per frame by the **worst** shortfall among the feet the
## IK currently owns, so the two legs cannot compound their compensation.
##
## This runs after the locomotion clips — the component is the last child of the
## model, so its `_process` is last — which matters: it reads the hip the clip
## just posed and offsets it, rather than accumulating an offset of its own
## across frames. That is also why the correction is a per-frame recompute and
## not a stored baseline: the clip owns the hips, this component only leans on
## them.
func _pelvis_prepare() -> void:
	var worst: float = 0.0
	var direction: Vector3 = Vector3.DOWN
	for side: int in SIDES.size():
		if _weight[side] <= 0.001:
			continue
		var chain: Dictionary = _chains[side]
		var upper: int = int(chain.get("upper", -1))
		var lower: int = int(chain.get("lower", -1))
		var foot: int = int(chain.get("foot", -1))
		if upper < 0 or lower < 0 or foot < 0:
			continue
		var l1: float = _rest_length(upper, lower)
		var l2: float = _rest_length(lower, foot)
		if l1 <= 0.0 or l2 <= 0.0:
			continue
		var to_target: Vector3 = _plant_pos[side] - _bone_origin(upper)
		var gap: float = to_target.length() - (l1 + l2)
		if gap > worst:
			worst = gap
			direction = to_target.normalized()
	if worst > 0.0:
		_drop_pelvis(direction, minf(worst, max_pelvis_drop))


## Move the hips toward `direction` by `amount`, expressed in the hips' own
## parent space. Returns the world-space move so a caller can keep solving
## against the hip's new position.
func _drop_pelvis(direction: Vector3, amount: float) -> Vector3:
	var hips: int = _skeleton.find_bone(HIPS_BONE)
	if hips < 0 or amount <= 0.0:
		return Vector3.ZERO
	var parent: int = _skeleton.get_bone_parent(hips)
	var parent_global: Basis = Basis.IDENTITY
	if parent >= 0:
		parent_global = _skeleton.get_bone_global_pose(parent).basis
	var world_offset: Vector3 = direction * amount
	var pose := _skeleton.get_bone_pose(hips)
	_skeleton.set_bone_pose_position(
		hips, pose.origin + parent_global.inverse() * world_offset)
	_applied_global[HIPS_BONE] = parent_global * _skeleton.get_bone_pose(hips).basis
	return world_offset


func _near_camera() -> bool:
	var camera: Camera3D = _model.get_viewport().get_camera_3d()
	if camera == null:
		return false
	return camera.global_position.distance_to(_model.global_position) < active_range


func _process_foot(side: int, delta: float) -> void:
	var chain: Dictionary = _chains[side]
	var foot: int = int(chain.get("foot", -1))
	if foot < 0:
		return
	var foot_pos: Vector3 = _bone_origin(foot)
	var ground: Variant = _ground_under(foot_pos)
	var clearance: float = INF
	if ground != null:
		clearance = foot_pos.y - (ground as Vector3).y - ANKLE_HEIGHT
	_clearance[side] = clearance
	_grounded[side] = ground != null
	var release_at: float = plant_exit if _planted[side] else plant_enter
	if ground == null or clearance > release_at:
		# Swing phase — the clip owns the foot, this only fades its own correction
		# out.
		_planted[side] = false
		_weight[side] = move_toward(_weight[side], 0.0, blend_speed * delta)
		return
	if not _planted[side]:
		_planted[side] = true
		# Pin to the **ground**, not to wherever the foot was when the test
		# fired. A landing frame catches the foot a few centimetres up; pinning
		# that height leaves the clearance hovering at the threshold forever, the
		# plant flag chatters, and every re-plant re-pins the current position —
		# which is the sliding this component exists to remove.
		_plant_pos[side] = Vector3(foot_pos.x, (ground as Vector3).y + ANKLE_HEIGHT, foot_pos.z)
		_plant_time[side] = 0.0
	_plant_time[side] += delta
	if _plant_time[side] > plant_max_time:
		_planted[side] = false
		_weight[side] = move_toward(_weight[side], 0.0, blend_speed * delta)
		return
	_weight[side] = move_toward(_weight[side], 1.0, blend_speed * delta)
	if _weight[side] <= 0.001:
		return
	_solve(side, _plant_pos[side], _weight[side])
	_ik_error[side] = (_bone_origin(int((_chains[side] as Dictionary)["foot"])) - _plant_pos[side]).length()


## The two-bone solve: put the foot on `target`, with `weight` deciding how much
## of the correction is applied (0 = leave the clip's pose alone).
##
## Both rotations are *swing the current direction onto the wanted one* about
## the bend plane's normal — the thigh first, then the shin, each measured after
## the previous one has been placed. Using the law-of-cosines hip angle as a
## rotation instead (the obvious first cut) only works when the leg is already
## straight: an animated leg is bent, its chain direction is not the target
## direction, and the correction lands somewhere the foot never asked to be —
## measured as 10-30 cm of error and a foot that still slides.
func _solve(side: int, target: Vector3, weight: float) -> void:
	var chain: Dictionary = _chains[side]
	var upper: int = int(chain["upper"])
	var lower: int = int(chain["lower"])
	var foot: int = int(chain["foot"])
	if upper < 0 or lower < 0 or foot < 0:
		return
	# Bone length: the distance from this bone's origin to the next one's. (Not
	# the rest transform's Y axis — on this rig that reads 1.0 for every
	# bone, Godot storing rest rotations without scale.)
	var l1: float = _rest_length(upper, lower)
	var l2: float = _rest_length(lower, foot)
	if l1 <= 0.0 or l2 <= 0.0:
		return
	var hip: Vector3 = _bone_origin(upper)
	var to_target: Vector3 = target - hip
	if to_target.length() < 0.001:
		return
	# The pelvis has already been dropped this frame (`_pelvis_prepare`), so the
	# hip here is the compensated one and the goal is back inside the reach.
	_last_reach[side] = Vector3(l1, l2, to_target.length())
	# Clamp the goal into the chain's reach so the two swings stay consistent
	# instead of asking for a length the leg does not have.
	var reach: float = clampf(to_target.length(), absf(l1 - l2) + 0.001, l1 + l2 - 0.001)
	var goal: Vector3 = hip + to_target.normalized() * reach
	# The knee folds in a fixed plane so the legs always bend the same way
	# without the rig's rest axes leaking in. The sign matters and is not
	# guessable: the first build used the character's right axis and the
	# photographed result was a backwards knee (thigh straight down, shin
	# folded behind) — the rotations ran the wrong way round the bend.
	var bend_normal: Vector3 = -_model.global_transform.basis.x.normalized()
	if absf(bend_normal.dot(to_target.normalized())) > 0.99:
		bend_normal = _model.global_transform.basis.z.normalized()
	var thigh_dir: Vector3 = (_bone_origin(lower) - hip).normalized()
	_aim(upper, bend_normal,
		thigh_dir.signed_angle_to((goal - hip).normalized(), bend_normal), weight)
	var knee_after: Vector3 = _bone_origin(lower)
	var shin_dir: Vector3 = (_bone_origin(foot) - knee_after).normalized()
	_aim(lower, bend_normal,
		shin_dir.signed_angle_to((goal - knee_after).normalized(), bend_normal), weight)


## Rotate one bone by `angle` about `axis`, blended in by `weight`, using the
## `parent_global · pose` convention documented at the top of the file.
func _aim(bone: int, axis: Vector3, angle: float, weight: float) -> void:
	if absf(angle) < 0.0001:
		return
	var name: String = _skeleton.get_bone_name(bone)
	var parent := _skeleton.get_bone_parent(bone)
	var parent_global: Basis = _applied_global.get(
		name if parent < 0 else _skeleton.get_bone_name(parent),
		# The **current** global pose, not the rest: the locomotion clip has
		# already moved the hips this frame, and solving against a stale rest
		# parent puts the correction in the wrong frame — it went unnoticed in
		# `ModelStance` only because a standing figure's rest *is* its pose.
		_skeleton.get_bone_global_pose(parent).basis if parent >= 0 else Basis.IDENTITY
	)
	var current: Basis = parent_global * _skeleton.get_bone_pose(bone).basis
	var rotation := Quaternion(axis, angle)
	rotation = Quaternion.IDENTITY.slerp(rotation, weight)
	var correction := Basis(rotation)
	var pose: Basis = parent_global.inverse() * correction * current
	_skeleton.set_bone_pose_rotation(bone, pose.get_rotation_quaternion())
	_applied_global[name] = correction * current


## Hip and knee angles (radians) that put a two-bone chain's end at distance `d`,
## by the law of cosines, with the reach clamped so the chain never has to bend
## backwards or snap straight. `x` is the upper bone, `y` the knee bend.
static func two_bone_angles(l1: float, l2: float, d: float) -> Vector2:
	# The epsilon is a tenth of a millimetre: on a 0.4 m bone a 1 mm gap already
	# costs ~4° of knee bend, which is visible as a permanently bent knee.
	var reach: float = clampf(d, absf(l1 - l2) + 0.0001, l1 + l2 - 0.0001)
	var cos_knee: float = clampf(
		(l1 * l1 + l2 * l2 - reach * reach) / (2.0 * l1 * l2), -1.0, 1.0)
	var knee: float = PI - acos(cos_knee)
	var cos_hip: float = clampf(
		(l1 * l1 + reach * reach - l2 * l2) / (2.0 * l1 * reach), -1.0, 1.0)
	return Vector2(acos(cos_hip), knee)


# --- geometry helpers ------------------------------------------------------

## The bone's tail in world space: its origin plus the child offset that points
## the bone the way it points.
func _bone_tail(bone: int) -> Vector3:
	var global_pose := _skeleton.global_transform * _skeleton.get_bone_global_pose(bone)
	return global_pose.origin + global_pose.basis.y.normalized() \
		* _rest_length(bone, -1, true)


func _bone_origin(bone: int) -> Vector3:
	return (_skeleton.global_transform * _skeleton.get_bone_global_pose(bone)).origin


## Rest distance to `other` (or to this bone's own tail when `other` is -1).
func _rest_length(bone: int, other: int, own_tail: bool = false) -> float:
	var pose := _skeleton.get_bone_global_rest(bone)
	if own_tail:
		return pose.basis.y.length()
	if other < 0:
		return 0.0
	return pose.origin.distance_to(_skeleton.get_bone_global_rest(other).origin)


func _ground_under(from: Vector3) -> Variant:
	var space: PhysicsDirectSpaceState3D = _model.get_world_3d().direct_space_state
	if space == null:
		return null
	var query := PhysicsRayQueryParameters3D.create(
		from + Vector3.UP * ray_up, from - Vector3.UP * ray_down, 1)
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return null
	return hit.get("position", from) as Vector3


## The current correction weight of one side — read by the walk probe to prove
## feet stay put instead of proving it with a screenshot.
func foot_weight(side: int) -> float:
	return _weight[side] if side >= 0 and side < _weight.size() else 0.0


func is_planted(side: int) -> bool:
	return _planted[side] if side >= 0 and side < _planted.size() else false


## The chain lengths and goal distance the last solve worked with — a leg
## straightened by the reach clamp looks identical to a leg with no bend until
## you can see the numbers.
func last_reach(side: int) -> Vector3:
	return _last_reach[side] if side >= 0 and side < _last_reach.size() else Vector3.ZERO


## Diagnostics for the walk probe: how high the foot sits over the ground, and
## whether the ground ray hit at all. A phase test that never fires looks
## identical to a broken one without these.
func last_clearance(side: int) -> float:
	return _clearance[side] if side >= 0 and side < _clearance.size() else 0.0


## Distance between where the solve aimed and where the foot actually landed.
## Large while planted means the two-bone solve is wrong; small with the foot
## still sliding means the measurement is.
func ik_error(side: int) -> float:
	return _ik_error[side] if side >= 0 and side < _ik_error.size() else 0.0


func ground_found(side: int) -> bool:
	return _grounded[side] if side >= 0 and side < _grounded.size() else false


## The foot's world position, for the same measurement.
func foot_world_pos(side: int) -> Vector3:
	if side < 0 or side >= _chains.size():
		return Vector3.ZERO
	var foot: int = int((_chains[side] as Dictionary).get("foot", -1))
	return _bone_origin(foot) if foot >= 0 else Vector3.ZERO
