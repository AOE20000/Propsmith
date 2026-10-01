extends Node3D
class_name CameraRig
## Orbit camera for the player. Yaw lives here, pitch lives on the spring arm's
## child pivot, so the character's facing can follow the camera without fighting
## the arm's collision response.

@export var target: Node3D = null
@export var mouse_sensitivity: float = 0.0026
@export var invert_y: bool = false
@export var min_pitch_degrees: float = -70.0
@export var max_pitch_degrees: float = 62.0
@export var follow_lerp: float = 14.0
## Height above the character's origin that the camera orbits.
@export var pivot_height: float = 1.6
## Distance the spring arm tries to hold.
@export var arm_length: float = 5.4
@export var capture_mouse_on_start: bool = true

var _pitch: float = -0.18
var _yaw: float = 0.0
var _spring_arm: SpringArm3D = null
var _pivot: Node3D = null


func _ready() -> void:
	_spring_arm = get_node_or_null("SpringArm3D") as SpringArm3D
	if _spring_arm != null:
		_pivot = _spring_arm.get_parent() as Node3D
		_spring_arm.spring_length = arm_length
	_yaw = global_rotation.y
	if capture_mouse_on_start:
		set_mouse_captured(true)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion: InputEventMouseMotion = event
		_yaw -= motion.relative.x * mouse_sensitivity
		var pitch_delta: float = motion.relative.y * mouse_sensitivity
		_pitch += -pitch_delta if invert_y else pitch_delta
		_pitch = clampf(
			_pitch,
			deg_to_rad(min_pitch_degrees),
			deg_to_rad(max_pitch_degrees)
		)
	elif event.is_action_pressed(&"ui_cancel"):
		set_mouse_captured(Input.mouse_mode != Input.MOUSE_MODE_CAPTURED)


func _process(delta: float) -> void:
	if target == null or not is_instance_valid(target):
		return
	var desired: Vector3 = target.global_position + Vector3.UP * pivot_height
	global_position = global_position.lerp(desired, clampf(follow_lerp * delta, 0.0, 1.0))
	rotation.y = _yaw
	if _pivot != null:
		_pivot.rotation.x = _pitch


func set_mouse_captured(captured: bool) -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if captured else Input.MOUSE_MODE_VISIBLE
	if not captured:
		GameState.mode = GameState.Mode.PAUSED


func yaw() -> float:
	return _yaw
