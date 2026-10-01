extends CharacterBody3D
class_name Player
## Third-person explorer. Owns movement, stamina and the camera rig; everything
## else (interaction, combat, inventory) is a child component that reads state
## from here, so a module can be removed without touching this file.
##
## Grounded movement uses Jolt's floor detection rather than a hand-rolled
## raycast, which keeps slopes and steps consistent with the physics engine.

@export_group("Movement")
@export var walk_speed: float = 5.2
@export var sprint_speed: float = 8.6
@export var acceleration: float = 14.0
@export var deceleration: float = 18.0
@export var air_control: float = 0.28
@export var jump_velocity: float = 6.4
@export var gravity: float = 22.0
## Ground steeper than this cannot be climbed and the player slides.
@export var max_slope_degrees: float = 46.0
@export var coyote_time: float = 0.12
@export var jump_buffer_time: float = 0.14

@export_group("Stamina")
@export var max_stamina: float = 100.0
@export var stamina_drain_per_second: float = 14.0
@export var stamina_regen_per_second: float = 20.0
## Sprinting below this fraction is refused, so the player cannot stutter-run.
@export var stamina_sprint_floor: float = 0.12

@export_group("Nodes")
## Optional explicit path; when empty the rig is found by name or by type, so a
## scene built in code and a hand-made scene both work without edits.
@export var camera_rig_path: NodePath = ^""

var stamina: float = 100.0
var is_sprinting: bool = false
var is_grounded: bool = false
var speed: float = 0.0

var camera_rig: Node3D = null
var camera: Camera3D = null

var _coyote_timer: float = 0.0
var _jump_buffer_timer: float = 0.0
var _was_grounded_last_frame: bool = false
var _gravity_scale: float = 1.0


func _ready() -> void:
	add_to_group(&"player")
	motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	floor_max_angle = deg_to_rad(max_slope_degrees)
	floor_snap_length = 0.35
	slide_on_ceiling = true
	stamina = max_stamina

	camera_rig = _resolve_camera_rig()
	if camera_rig != null:
		camera = camera_rig.get_node_or_null("SpringArm3D/Camera3D") as Camera3D
		if camera == null:
			camera = camera_rig.find_child("Camera3D", true, false) as Camera3D
		camera_rig.set("target", self)

	if not GameState.has_spawn_position:
		GameState.set_spawn(global_position)


## Prefer the exported path, then a child named CameraRig, then any CameraRig in
## the subtree. Being tolerant here is what lets the scene be assembled in code.
func _resolve_camera_rig() -> Node3D:
	if not camera_rig_path.is_empty():
		var explicit: Node3D = get_node_or_null(camera_rig_path) as Node3D
		if explicit != null:
			return explicit
	var named: Node3D = get_node_or_null("CameraRig") as Node3D
	if named != null:
		return named
	for child: Node in get_children():
		if child is CameraRig:
			return child
	return null


func _physics_process(delta: float) -> void:
	is_grounded = is_on_floor()
	if is_grounded:
		_coyote_timer = coyote_time
	else:
		_coyote_timer = maxf(_coyote_timer - delta, 0.0)
		_was_grounded_last_frame = false

	if Input.is_action_just_pressed(&"jump"):
		_jump_buffer_timer = jump_buffer_time
	else:
		_jump_buffer_timer = maxf(_jump_buffer_timer - delta, 0.0)

	var input_vector: Vector2 = Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back")
	var wants_sprint: bool = Input.is_action_pressed(&"sprint") and input_vector.length_squared() > 0.01
	_update_stamina(delta, wants_sprint)

	var basis_yaw: float = camera_rig.global_rotation.y if camera_rig != null else global_rotation.y
	var direction: Vector3 = (Vector3(input_vector.x, 0.0, input_vector.y).rotated(Vector3.UP, basis_yaw)).normalized()

	var target_speed: float = sprint_speed if is_sprinting else walk_speed
	var target_velocity: Vector3 = direction * target_speed
	var current_flat := Vector3(velocity.x, 0.0, velocity.z)
	var rate: float = acceleration if direction.length_squared() > 0.01 else deceleration
	if not is_grounded:
		rate *= air_control
	current_flat = current_flat.move_toward(target_velocity, rate * delta)

	velocity.x = current_flat.x
	velocity.z = current_flat.z

	if _jump_buffer_timer > 0.0 and _coyote_timer > 0.0:
		velocity.y = jump_velocity
		_jump_buffer_timer = 0.0
		_coyote_timer = 0.0
	elif is_grounded and velocity.y < 0.0:
		# A small downward bias keeps the body glued to slopes.
		velocity.y = -1.5
	else:
		velocity.y -= gravity * _gravity_scale * delta
		velocity.y = maxf(velocity.y, -55.0)

	move_and_slide()
	speed = Vector2(velocity.x, velocity.z).length()
	_track_distance_travelled(delta)

	if global_position.y < -40.0:
		_respawn()


func _update_stamina(delta: float, wants_sprint: bool) -> void:
	var was_sprinting: bool = is_sprinting
	if wants_sprint and is_grounded and stamina > max_stamina * stamina_sprint_floor:
		is_sprinting = true
		stamina = maxf(stamina - stamina_drain_per_second * delta, 0.0)
	elif wants_sprint and is_sprinting and stamina > 0.0:
		# Keep sprinting while airborne if it was already engaged.
		stamina = maxf(stamina - stamina_drain_per_second * 0.5 * delta, 0.0)
	else:
		is_sprinting = false
		stamina = minf(stamina + stamina_regen_per_second * delta, max_stamina)

	if was_sprinting != is_sprinting or fmod(stamina, 1.0) < delta * stamina_regen_per_second:
		Events.player_stamina_changed.emit(stamina, max_stamina)


func _track_distance_travelled(delta: float) -> void:
	if delta <= 0.0:
		return
	GameState.total_distance_travelled += speed * delta


## Teleport to the recorded spawn; used by falling out of the world and by the
## pause menu's "return to start".
func _respawn() -> void:
	var target: Vector3 = GameState.spawn_position
	if not GameState.has_spawn_position:
		var query: TerrainQuery = Services.get_as(&"terrain_query", &"TerrainQuery") as TerrainQuery
		target = query.sample_height(Vector3.ZERO, 2.0) if query != null else Vector3(0.0, 6.0, 0.0)
	global_position = target
	velocity = Vector3.ZERO
	Events.player_respawned.emit(self)
	Events.notify("已回到出生点", Events.NotifyLevel.WARNING)


func respawn() -> void:
	_respawn()


## Facing direction on the horizontal plane, which is what attacks and
## interactions aim with.
func facing_direction() -> Vector3:
	if camera_rig != null:
		return -Vector3(sin(camera_rig.global_rotation.y), 0.0, cos(camera_rig.global_rotation.y)).normalized()
	return -global_transform.basis.z


func eye_position() -> Vector3:
	return global_position + Vector3.UP * 1.55


func serializable() -> Dictionary:
	return {
		"position": SaveSystem.encode_variant(global_position),
		"stamina": stamina,
	}


func restore(data: Dictionary) -> void:
	var restored: Variant = SaveSystem.decode_variant(data.get("position", null))
	if restored is Vector3:
		global_position = restored
		velocity = Vector3.ZERO
	stamina = float(data.get("stamina", max_stamina))
