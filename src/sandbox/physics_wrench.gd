extends Node
class_name PhysicsWrench
## The grab tool: aim at a prop, hold the primary button, and a temporary joint
## pulls it along your aim — with the hold distance on the wheel, rotation while
## the interact key is held (Shift adds pitch), freeze on the secondary button,
## unfreeze on R, and remove on X.
##
## The grab is a `Generic6DOFJoint3D` between the held body and a static anchor
## that tracks the crosshair every physics frame. A joint (rather than teleporting
## the body toward the point) gives the beam its springy, weight-respecting feel:
## heavy props lag, light props snap, and props caught on geometry genuinely snag
## instead of gliding through walls.
##
## Active only while the belt holds the wrench (`ToolBelt.current`), which is
## also what makes the same mouse button mean "attack" or "grab" depending on
## what the player is holding — one button, one owner at a time.

const THROW_SPEED: float = 12.0
const GRAB_RANGE: float = 12.0
const HOLD_DISTANCE_MIN: float = 2.0
const HOLD_DISTANCE_MAX: float = 10.0
const ROTATE_SENSITIVITY: float = 0.008

var _held: RigidBody3D = null
var _anchor: StaticBody3D = null
var _joint: Generic6DOFJoint3D = null
var _hold_distance: float = 4.0


func _ready() -> void:
	# The anchor exists for the whole session; the joint is created per grab.
	_anchor = StaticBody3D.new()
	_anchor.name = "WrenchAnchor"
	add_child(_anchor)


func _physics_process(_delta: float) -> void:
	if _held == null:
		return
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null:
		return
	# The anchor rides the crosshair; the joint does the pulling.
	var forward: Vector3 = -camera.global_transform.basis.z
	_anchor.global_position = camera.global_position + forward * _hold_distance


func _unhandled_input(event: InputEvent) -> void:
	if GameState.mode != GameState.Mode.EXPLORING:
		return
	var belt: Variant = Services.get_service(&"tool_belt")
	if belt == null or (belt as ToolBelt).current != &"wrench":
		return

	if event.is_action_pressed(&"attack"):
		_grab_or_release()
		get_viewport().set_input_as_handled()
	elif event.is_action_released(&"attack"):
		if _held != null:
			_release()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"wrench_freeze"):
		_freeze_held()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"prop_unfreeze"):
		_unfreeze_aimed()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"prop_delete"):
		_remove_aimed()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_WHEEL_UP:
			_hold_distance = clampf(_hold_distance + 0.6, HOLD_DISTANCE_MIN, HOLD_DISTANCE_MAX)
			get_viewport().set_input_as_handled()
		elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_hold_distance = clampf(_hold_distance - 0.6, HOLD_DISTANCE_MIN, HOLD_DISTANCE_MAX)
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _held != null and Input.is_action_pressed(&"interact"):
		# Rotation while held: mouse motion turns the anchor, and the joint
		# carries the body along. Shift adds pitch (aligned to the camera).
		var motion := event as InputEventMouseMotion
		_anchor.global_rotate(Vector3.UP, -motion.relative.x * ROTATE_SENSITIVITY)
		if Input.is_key_pressed(Key.KEY_SHIFT):
			var camera: Camera3D = get_viewport().get_camera_3d()
			if camera != null:
				_anchor.global_rotate(camera.global_transform.basis.x, -motion.relative.y * ROTATE_SENSITIVITY)
		get_viewport().set_input_as_handled()


func _grab_or_release() -> void:
	if _held != null:
		_release()
		return
	var target := _aimed_body()
	if target == null:
		return
	if target.freeze:
		# Aiming at a frozen prop and grabbing it IS the unfreeze, exactly the
		# behaviour the reference controls use.
		_set_frozen(target, false)
	_attach(target)


func _release() -> void:
	# Drop the grab-time collision exception with whoever is holding it, so the
	# prop collides with that character again the moment it is let go.
	if _held != null and is_instance_valid(_held):
		var player: Node = get_tree().get_first_node_in_group(&"player")
		if player is PhysicsBody3D:
			_held.remove_collision_exception_with(player as PhysicsBody3D)
	if _joint != null and is_instance_valid(_joint):
		_joint.queue_free()
	_joint = null
	_held = null


## Throw: release with the camera's forward velocity added.
func throw_held() -> void:
	if _held == null:
		return
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera != null:
		_held.linear_velocity = -camera.global_transform.basis.z * THROW_SPEED
	_release()


func _freeze_held() -> void:
	if _held == null:
		return
	_set_frozen(_held, true)
	_release()


func _unfreeze_aimed() -> void:
	var target := _aimed_body()
	if target != null and target.freeze:
		_set_frozen(target, false)


func _remove_aimed() -> void:
	var target := _aimed_body()
	if target == null:
		return
	if _held == target:
		_release()
	var spawner: PropSpawner = Services.get_as(&"prop_spawner", &"PropSpawner") as PropSpawner
	if spawner != null:
		spawner.remove(target)


func _set_frozen(target: RigidBody3D, frozen: bool) -> void:
	target.freeze = frozen
	PropFactory.set_frozen_look(target, frozen)
	Events.prop_frozen.emit(target, frozen)


## The dynamic body under the crosshair, within grab range.
func _aimed_body() -> RigidBody3D:
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null:
		return null
	var query := PhysicsRayQueryParameters3D.create(
		camera.global_position,
		camera.global_position - camera.global_transform.basis.z * GRAB_RANGE,
		1,
	)
	var hit: Dictionary = camera.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return null
	return hit.get("collider") as RigidBody3D


## Attach the held body to the tracking anchor at the body's own position, so
## the first frames pull nothing — the anchor then glides to the hold distance.
## The joint must be in the tree before node_a/node_b: paths need a common
## ancestor, which only exists once it is added.
func _attach(target: RigidBody3D) -> void:
	_held = target
	# The hold length starts where the prop already is: grabbing a crate across
	# the yard must not yank it to a fixed four metres — the anchor begins on
	# the body and only follows the crosshair from there. The wheel still
	# adjusts it afterwards.
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera != null:
		_hold_distance = clampf(
			camera.global_position.distance_to(target.global_position),
			HOLD_DISTANCE_MIN, HOLD_DISTANCE_MAX)
	_anchor.global_position = _held.global_position
	_anchor.global_rotation = Vector3.ZERO
	_joint = Generic6DOFJoint3D.new()
	_joint.name = "WrenchJoint"
	add_child(_joint)
	_joint.node_a = _joint.get_path_to(_anchor)
	_joint.node_b = _joint.get_path_to(_held)
	# A held prop must not shove the player it is held by: the beam pulls the
	# body, and without this the body pushes back through the character
	# whenever the two get close.
	var player: Node = get_tree().get_first_node_in_group(&"player")
	if player is PhysicsBody3D:
		_held.add_collision_exception_with(player as PhysicsBody3D)
