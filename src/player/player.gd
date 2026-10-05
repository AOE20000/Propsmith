extends CharacterBody3D
class_name Player
## Third-person explorer. Owns movement, stamina and the camera rig; everything
## else (interaction, combat, inventory) is a child component that reads state
## from here, so a module can be removed without touching this file.
##
## Grounded movement uses Jolt's floor detection rather than a hand-rolled
## raycast, which keeps slopes and steps consistent with the physics engine.
##
## The character can be lent out. `take_control()` hands movement to another node
## — a vehicle seat, or the debug free camera — which is what lets those features
## exist without either of them reaching into this script or duplicating its
## physics. The third movement tier, crouching, is carried over from the sandbox
## prototype this project's player is descended from.

## Body dimensions live here rather than in the scene builder so the crouch
## collider and the stand-up clearance test cannot drift from the geometry that was
## actually built. `PlayerScene` reads these.
const BODY_HEIGHT: float = 1.8
const BODY_RADIUS: float = 0.35
## Height above the origin the camera orbits at when standing.
## Camera height while standing. The base figure is a touch under 1.8 m to the
## crown; this sits above the chest and below the neck root — the level a
## first-person camera reads as natural. 1.55 was reported as looking "a bit
## high and centred", i.e. at the collarbone rather than at the eyes of a
## head that in first person is not drawn.
const EYE_HEIGHT: float = 1.38

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

@export_group("Crouch")
## Crouch is a *pose*, not just a slower tier: it shortens the collider and drops
## the camera, so it is what lets the character pass under something. Standing back
## up is refused while there is no headroom, which is what keeps it honest.
@export var crouch_speed: float = 2.4
## How fast the body swings to face the movement direction (rad/s) in third
## person. The camera rig subtracts this turn from its own yaw, so the view
## keeps its heading while the body pivots under it.
@export var turn_speed: float = 10.0
## How fast the body follows the *view* in first person (rad/s) — deliberately
## slower than `turn_speed`: the head leads (it absorbs the look difference up
## to its own limit, see `ModelHeadAim`) and the shoulders catch up after, so
## looking around reads as looking, not as spinning on the spot.
@export var body_follow_speed: float = 3.0
## Fraction of the standing height the body shrinks to when fully crouched.
@export var crouch_body_scale: float = 0.58
@export var crouch_transition_per_second: float = 8.0

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
var is_crouching: bool = false
var speed: float = 0.0

## Non-null while another node drives this character: a vehicle seat or the debug
## free camera. Movement, gravity and stamina are suspended rather than zeroed, and
## the collider is switched off so the rider cannot shove whatever it is riding.
var external_controller: Object = null

## Whether the player's own camera should consume look input. A controller that
## brings its own camera turns this off, so one mouse motion cannot steer both.
## Driving a vehicle deliberately leaves it on: looking around from the seat is the
## point, and the vehicle's steering comes from the movement keys, not the mouse.
var look_input_enabled: bool = true

var camera_rig: Node3D = null
var camera: Camera3D = null

var _coyote_timer: float = 0.0
var _jump_buffer_timer: float = 0.0
var _was_grounded_last_frame: bool = false
var _gravity_scale: float = 1.0
## 0 = standing, 1 = fully crouched. Kept as a float so the transition can be
## interpolated instead of snapping the collider.
var _crouch_amount: float = 0.0
var _collider: CollisionShape3D = null
var _capsule: CapsuleShape3D = null
var _visual: Node3D = null


func _ready() -> void:
	add_to_group(&"player")
	motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	floor_max_angle = deg_to_rad(max_slope_degrees)
	floor_snap_length = 0.35
	slide_on_ceiling = true
	stamina = max_stamina

	_collider = get_node_or_null("CollisionShape3D") as CollisionShape3D
	if _collider != null:
		_capsule = _collider.shape as CapsuleShape3D
	_visual = get_node_or_null("Visual") as Node3D

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
	if external_controller != null:
		# Something else has the character. Return before touching `velocity` or
		# stamina: the controller owns the transform, and leaving the physics
		# stepping here would have two systems writing the same body.
		speed = 0.0
		return

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

	_update_crouch(delta)

	var input_vector: Vector2 = Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back")
	var wants_sprint: bool = (
		Input.is_action_pressed(&"sprint")
		and input_vector.length_squared() > 0.01
		and not is_crouching
	)
	_update_stamina(delta, wants_sprint)

	var basis_yaw: float = camera_rig.global_rotation.y if camera_rig != null else global_rotation.y
	var direction: Vector3 = (Vector3(input_vector.x, 0.0, input_vector.y).rotated(Vector3.UP, basis_yaw)).normalized()

	var target_speed: float = crouch_speed if is_crouching else (sprint_speed if is_sprinting else walk_speed)
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
	_update_facing(delta)
	_track_distance_travelled(delta)

	if global_position.y < -40.0:
		_respawn()


## Turn the body. Two regimes, because they answer different questions:
##
## * **Third person** — the character goes where it walks: the body turns
##   toward the movement direction at a constant angular rate. A fixed rate
##   (rather than an exponential `lerp_angle`) is also what stops a 180°
##   reversal from dithering: `lerp_angle`'s direction is undefined at exactly
##   π, so the body oscillated and the camera — which compensates for the
##   body's turn — read that as about a second of jitter. `angle_difference`
##   picks a side deterministically and the rate is bounded.
## * **First person** — the body belongs to the view, not to the movement:
##   strafing and backpedalling must not spin the character. It follows the
##   view's yaw slowly, with the head leading (see `ModelHeadAim`).
func _update_facing(delta: float) -> void:
	var flat := Vector2(velocity.x, velocity.z)
	var target_yaw: float
	var rate: float = turn_speed
	if camera_rig != null and camera_rig.is_first_person():
		target_yaw = camera_rig.get_view_yaw()
		rate = body_follow_speed
	else:
		if flat.length_squared() < 0.01:
			return
		# The body's forward is -Z (the model's own 180° flip is authored in
		# `player_scene`), so the yaw that faces `flat` is atan2(-x, -z).
		target_yaw = atan2(-flat.x, -flat.y)
	var diff := angle_difference(rotation.y, target_yaw)
	rotation.y += clampf(diff, -rate * delta, rate * delta)


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


## Resolve this frame's crouch intent, then move the pose toward it.
##
## Release is conditional on headroom while engage is not: that asymmetry is the
## whole feature — you may crouch anywhere, but you only stand up where standing
## fits, so crouching cannot be used to clip through a ceiling.
func _update_crouch(delta: float) -> void:
	var wants_crouch: bool = Input.is_action_pressed(&"crouch") and is_grounded
	if is_crouching and not wants_crouch and not _has_headroom():
		wants_crouch = true
	is_crouching = wants_crouch
	if is_crouching:
		is_sprinting = false
	var target: float = 1.0 if is_crouching else 0.0
	_crouch_amount = move_toward(_crouch_amount, target, crouch_transition_per_second * delta)
	_apply_crouch_pose()


## Squash the visual, the collider and the camera together by one factor. Scaling
## the visual node at the origin keeps the feet planted, because the mesh inside it
## is authored from the ground up.
func _apply_crouch_pose() -> void:
	var scale_y: float = lerpf(1.0, crouch_body_scale, _crouch_amount)
	if _visual != null:
		_visual.scale = Vector3(1.0, scale_y, 1.0)
	if _capsule != null:
		_capsule.height = BODY_HEIGHT * scale_y
	if _collider != null:
		_collider.position.y = BODY_HEIGHT * 0.5 * scale_y
	if camera_rig != null:
		camera_rig.set("pivot_height", _current_eye_height())


func _current_eye_height() -> float:
	return EYE_HEIGHT * lerpf(1.0, crouch_body_scale, _crouch_amount)


## Is there room to be standing here? A shape query with the full-height capsule,
## excluding the player's own body, which is the only way to ask the physics engine
## a question the character controller cannot answer itself.
func _has_headroom() -> bool:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if space == null:
		return true
	var query := PhysicsShapeQueryParameters3D.new()
	var standing := CapsuleShape3D.new()
	standing.height = BODY_HEIGHT
	standing.radius = BODY_RADIUS
	query.shape = standing
	query.transform = Transform3D(Basis(), global_position + Vector3.UP * (BODY_HEIGHT * 0.5))
	query.collision_mask = collision_mask
	query.exclude = [get_rid()]
	# One result is enough: the question is only whether anything is in the way.
	return space.intersect_shape(query, 1).is_empty()


## Hand movement to another node. Returns whether this player is now driven by
## `controller`; a second claimant is refused rather than silently winning, so two
## vehicles can never both believe they are driving.
func take_control(controller: Object) -> bool:
	if controller == null:
		return false
	if external_controller == controller:
		return true
	if external_controller != null:
		push_warning("Player.take_control: already controlled by %s" % external_controller)
		return false
	external_controller = controller
	velocity = Vector3.ZERO
	speed = 0.0
	is_sprinting = false
	_set_body_enabled(false)
	return true


## Take movement back. The controller is told first so it can clear its own
## occupancy flag, then the character detaches unconditionally: a controller that
## ignores the callback still ends up released instead of holding the player.
func release_external_control() -> void:
	if external_controller == null:
		return
	var controller: Object = external_controller
	external_controller = null
	if controller.has_method("release_rider"):
		controller.call("release_rider", self)
	_set_body_enabled(true)
	look_input_enabled = true


func is_externally_controlled() -> bool:
	return external_controller != null


## The collider is switched off rather than the node being reparented. Reparenting
## a `CharacterBody3D` under a moving rigid body makes the two colliders fight;
## suspending this one and driving the transform is what the vehicle prototype's
## player-in-cabin reparenting was reaching for.
func _set_body_enabled(enabled: bool) -> void:
	if _collider != null:
		_collider.disabled = not enabled


## Teleport to the recorded spawn; used by falling out of the world and by the
## pause menu's "return to start".
func _respawn() -> void:
	# Detach before moving: respawning out from under a seat would otherwise leave
	# the vehicle driving a character that is no longer in it.
	release_external_control()
	var target: Vector3 = GameState.spawn_position
	if not GameState.has_spawn_position:
		var query: SurfaceQuery = Services.get_as(&"surface_query", &"SurfaceQuery") as SurfaceQuery
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
	return global_position + Vector3.UP * _current_eye_height()


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
