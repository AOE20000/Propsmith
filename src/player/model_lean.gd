extends Node
class_name ModelLean
## Leans the torso with speed and steering — weight you can *see*, without a
## single new animation.
##
## Two channels, both derived instead of authored:
##   * **Forward pitch** scales with planar speed. A running figure that stays
##     bolt-upright reads as a mannequin on wheels; the same figure pitched a
##     few degrees into its motion reads as carrying momentum.
##   * **Roll** scales with the yaw change rate. Turning hard tips the torso
##     into the corner, the way everything with mass does.
##
## Both inputs are read per frame and **damped before they reach the goals**.
## That is not polish, it is the difference between weight and a glitch: the
## raw per-frame yaw rate of a turning body is a spike train (physics ticks
## land unevenly across render frames), and an undamped roll snapped to its
## cap on every start — the "the character suddenly tips over, then starts
## moving" the playtest reported. The reads stay deliberately raw (not
## `get_global_transform_interpolated()`): this component must also measure
## figures that move outside the physics tick — citizens on scripted paths,
## probe and test rigs — where the interpolated transform never advances. The
## dampers *are* the smoothing.
##
## The ease itself is deliberately slower than the velocity changes it
## follows: the torso has mass, and the lean arriving with the *stride* —
## not with the velocity step — is what keeps starts and stops coordinated.
## On a stop the legs recover over the stop blend plus the standstill
## handback (~0.4 s); a lean that snapped upright ahead of them read as the
## body correcting while the legs were still busy.
##
## Writes the chest bone's *rotation* on top of whatever the locomotion clip
## left there (the clip owns the pose; this is the overlay, and the chest's
## scale is owned by `ModelStance` — rotation and scale are separate channels,
## so the two do not fight). As with `ModelHeadAim`, that substrate is re-written
## every frame by an earlier writer, which is what keeps this from accumulating.

## Forward pitch at full sprint (degrees).
@export var max_forward_degrees: float = 6.0
## Roll at a hard turn (degrees).
@export var max_roll_degrees: float = 3.5
## Planar speed at which the forward pitch is fully leaned in. Matches the
## sprint speed the player caps at.
@export var speed_ref: float = 8.6
## How fast the lean eases toward its goal (per second). Slower than the
## velocity it follows on purpose — see the header: the lean has to arrive
## with the stride and leave with the legs, not with the velocity step.
@export var ease_speed: float = 4.0
## How fast the smoothed yaw rate follows the raw per-frame one (per second).
## The raw signal is a spike train; this turns it into the cornering force it
## represents.
@export var yaw_rate_lerp: float = 6.0

var _model: Node3D = null
var _skeleton: Skeleton3D = null
var _chest: int = -1
var _prev_pos: Vector3 = Vector3.ZERO
var _prev_yaw: float = 0.0
var _yaw_rate: float = 0.0
var _pitch: float = 0.0
var _roll: float = 0.0
## Whether the motion anchor has been taken **in the tree**. `setup` runs
## while the model is still being assembled — usually outside the tree, where
## reading its global transform is an engine error — so the anchor is taken
## lazily on the first tick instead.
var _anchored: bool = false


## Bind to a model root. A model without a chest bone simply does not lean.
func setup(model: Node3D) -> void:
	_model = model
	if model == null:
		return
	for candidate: Node in model.find_children("*", "Skeleton3D", true, false):
		_skeleton = candidate as Skeleton3D
		break
	if _skeleton == null:
		return
	_chest = _skeleton.find_bone("Chest")
	_anchored = _model.is_inside_tree()
	if _anchored:
		_prev_pos = _model.global_position
		_prev_yaw = _model.global_rotation.y
	set_process(_chest >= 0)


func _process(delta: float) -> void:
	if _chest < 0 or _model == null or _skeleton == null:
		return
	if not _model.is_inside_tree():
		return
	if not _anchored:
		_prev_pos = _model.global_position
		_prev_yaw = _model.global_rotation.y
		_anchored = true
		return
	# Planar speed from the model root's own motion: the root does not carry
	# the bone animation (that lives in the children), so its translation *is*
	# the character's movement. Raw reads on purpose — see the header.
	var moved: Vector3 = _model.global_position - _prev_pos
	_prev_pos = _model.global_position
	var speed: float = Vector2(moved.x, moved.z).length() / maxf(delta, 1e-4)
	# Yaw change rate: positive when the figure turns left. The raw
	# per-frame derivative is a spike train (see the header); the smoothed
	# value is the cornering force it represents.
	var yaw: float = _model.global_rotation.y
	var raw_rate: float = angle_difference(_prev_yaw, yaw) / maxf(delta, 1e-4)
	_prev_yaw = yaw
	_yaw_rate = lerpf(_yaw_rate, raw_rate, 1.0 - exp(-yaw_rate_lerp * delta))

	var pitch_goal: float = deg_to_rad(max_forward_degrees) * clampf(
		speed / speed_ref, 0.0, 1.0)
	var roll_goal: float = deg_to_rad(max_roll_degrees) * clampf(
		_yaw_rate / 6.0, -1.0, 1.0)
	var rate: float = 1.0 - exp(-ease_speed * delta)
	_pitch = lerpf(_pitch, pitch_goal, rate)
	_roll = lerpf(_roll, roll_goal, rate)
	if absf(_pitch) < 0.0001 and absf(_roll) < 0.0001:
		return
	# Compose on top of the clip's chest pose (the same substrate trick as
	# `ModelHeadAim`): local X is the forward/backward axis, local Z the roll.
	var pose := _skeleton.get_bone_pose(_chest)
	var rotation := pose.basis.get_rotation_quaternion()
	rotation = rotation * Quaternion(Vector3(1.0, 0.0, 0.0), _pitch)
	rotation = rotation * Quaternion(Vector3(0.0, 0.0, 1.0), _roll)
	_skeleton.set_bone_pose_rotation(_chest, Basis(rotation))
