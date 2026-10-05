extends Node
class_name ModelHeadAim
## Turns the head before the body does.
##
## In first person the view is free while the body follows it slowly (see
## `Player.body_follow_speed`). The difference between the two lands on the
## head, up to a limit: looking around reads as a glance, and the shoulders
## catch up after — look first, body after. Third person leaves the head alone,
## where the body already faces the movement.
##
## Self-contained on purpose: it finds the camera through the viewport and
## decides "first person" by how close that camera is to the figure, so it needs
## no wiring to the player scene and does nothing at all for a citizen (whose
## camera, if any, is never at its eyeball).
##
## It is the *last* writer of the head's pose, and it relies on there being an
## earlier writer every frame — the locomotion clips on the walk, `ModelStance`
## otherwise (which re-asserts the head as a base). That is what lets it simply
## read-multiply-write: what it reads is always a clean pose, never its own
## output from last frame.

## Degrees the neck turns before the body must follow.
const MAX_YAW_DEGREES: float = 70.0
## A camera closer than this to the figure is an eye, not an observer.
const FIRST_PERSON_RANGE: float = 1.2
## How fast the head eases back when the look difference goes away (per second).
const EASE_SPEED: float = 14.0

var _model: Node3D = null
var _skeleton: Skeleton3D = null
var _head: int = -1
## The offset currently applied to the head (eased toward the look difference).
var _current: Quaternion = Quaternion.IDENTITY


## Bind to a model root. A model without a head bone simply never looks around.
func setup(model: Node3D) -> void:
	_model = model
	if model == null:
		return
	for node: Node in model.find_children("*", "Skeleton3D", true, false):
		_skeleton = node as Skeleton3D
		break
	if _skeleton == null:
		return
	_head = _skeleton.find_bone("Head")
	set_process(_head >= 0)


func _process(delta: float) -> void:
	if _head < 0 or _model == null or _skeleton == null:
		return
	if not _model.is_inside_tree():
		return
	var target: Quaternion = Quaternion.IDENTITY
	var camera := _model.get_viewport().get_camera_3d()
	if camera != null and camera.global_position.distance_to(
			_model.global_position) < FIRST_PERSON_RANGE:
		# The view's heading comes from its forward vector, not from a Euler
		# decomposition: with any pitch on the camera the yaw extracted from
		# the rotation would drift.
		var view_forward: Vector3 = -camera.global_transform.basis.z
		var view_yaw: float = atan2(-view_forward.x, -view_forward.z)
		# The model carries the authored 180° flip (see `player_scene`), so the
		# figure's own facing is the parent's yaw, not this node's.
		var body_yaw: float = _model.global_rotation.y - PI
		var offset: float = wrapf(view_yaw - body_yaw, -PI, PI)
		offset = clampf(
			offset, -deg_to_rad(MAX_YAW_DEGREES), deg_to_rad(MAX_YAW_DEGREES))
		target = Quaternion(Vector3.UP, offset)
	_current = _current.slerp(target, clampf(EASE_SPEED * delta, 0.0, 1.0))
	if _current.is_equal_approx(Quaternion.IDENTITY):
		return
	# Compose on top of whatever earlier writers left on the head (clip or
	# stance — both re-write it every frame).
	_skeleton.set_bone_pose_rotation(
		_head, _skeleton.get_bone_pose_rotation(_head) * _current)
