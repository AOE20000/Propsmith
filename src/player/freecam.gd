extends Camera3D
class_name Freecam
## Debug free camera — a noclip view for inspecting the generated island.
##
## Ported from `Freecam.gd` in craftablescience/godot-3d-sandbox, with the two
## things that had gone stale in the Godot 3 original fixed:
##
##   - movement is scaled by `delta` instead of a fixed amount per frame, so it no
##     longer flies at half speed on a 120 Hz display;
##   - it no longer reparents or disables the player. It *borrows* the character
##     through `Player.take_control()` and hands it back on exit, which is why this
##     file and the vehicle can coexist without agreeing on anything else.
##
## Depth is the point of the original, so the speed ladder is kept: a slow tier for
## threading through geometry, base flight, and a boost for crossing the island.
##
## Toggled with the `toggle_freecam` action. `GameState.mode` becomes `FREECAM`,
## which is what suspends interaction and attacks for the duration without either
## of those systems needing to know a camera exists.

@export_group("Movement")
@export var fly_speed: float = 14.0
## Multiplier while `sprint` is held.
@export var boost_multiplier: float = 3.2
## Multiplier while `crouch` is held.
@export var precision_multiplier: float = 0.25
@export var smoothing: float = 16.0

@export_group("Look")
@export var mouse_sensitivity: float = 0.0026
@export var invert_y: bool = false
## Asymmetric on purpose: the original clamped to ±70°, which lets you look far
## enough down to place a camera but not far enough up to lose the horizon.
@export var min_pitch_degrees: float = -85.0
@export var max_pitch_degrees: float = 85.0

var _active: bool = false
var _velocity: Vector3 = Vector3.ZERO
var _yaw: float = 0.0
var _pitch: float = 0.0


func _ready() -> void:
	# Off until asked for. `current` stays false so the player's own camera keeps
	# rendering the frame.
	current = false
	process_mode = Node.PROCESS_MODE_ALWAYS
	Events.game_mode_changed.connect(_on_game_mode_changed)


func is_active() -> bool:
	return _active


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"toggle_freecam"):
		set_active(not _active)
		get_viewport().set_input_as_handled()
		return
	if not _active:
		return
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
		_apply_look()


func _process(delta: float) -> void:
	if not _active:
		_velocity = Vector3.ZERO
		return

	# Axis strengths rather than a pressed/not-pressed test, so a gamepad or an
	# analog key binding flies proportionally instead of snapping to full speed.
	var forward_amount: float = (
		Input.get_action_strength(&"move_forward") - Input.get_action_strength(&"move_back")
	)
	var strafe_amount: float = (
		Input.get_action_strength(&"move_right") - Input.get_action_strength(&"move_left")
	)
	var vertical_amount: float = (
		Input.get_action_strength(&"jump") - Input.get_action_strength(&"crouch")
	)

	var speed: float = fly_speed
	if Input.is_action_pressed(&"sprint"):
		speed *= boost_multiplier
	if Input.is_action_pressed(&"crouch"):
		speed *= precision_multiplier

	# Fly along the view basis, so "up" on the stick means "into the screen".
	var basis: Basis = global_transform.basis
	var direction: Vector3 = (
		basis.x * strafe_amount
		+ (-basis.z) * forward_amount
		+ Vector3.UP * vertical_amount
	)
	if direction.length_squared() > 0.0:
		direction = direction.normalized()

	# Smoothed so the camera does not read as a teleport when the key goes down;
	# the original translated by a flat per-frame amount and felt like a glitch.
	_velocity = _velocity.lerp(direction * speed, clampf(smoothing * delta, 0.0, 1.0))
	global_position += _velocity * delta


## Turn the borrowed camera on or off. Everything that has to change for the mode
## to be coherent — the current camera, the player's control, the mouse, the game
## mode — is done here and its exact inverse on exit, so there is no second place
## where half of the transition can be forgotten.
func set_active(active: bool) -> void:
	if _active == active:
		return
	var player: Player = _resolve_player()

	if active:
		if player == null:
			push_warning("Freecam: no player to borrow — spawn order problem?")
			return
		global_position = player.eye_position()
		_yaw = player.camera_rig.global_rotation.y if player.camera_rig != null else 0.0
		_pitch = 0.0
		_apply_look()
		_velocity = Vector3.ZERO
		_active = true
		current = true
		# The player's rig must stop consuming the same mouse motion, or both
		# cameras would steer from one input.
		player.look_input_enabled = false
		player.take_control(self)
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		GameState.mode = GameState.Mode.FREECAM
		Events.notify("自由视角：再次按 F3 返回角色", Events.NotifyLevel.INFO)
	else:
		_active = false
		if player != null:
			player.release_external_control()
			_return_view_to_player(player)
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		GameState.mode = GameState.Mode.EXPLORING
		Events.notify("已回到角色视角", Events.NotifyLevel.INFO)


## `Player` calls this when it detaches us, including from `release_external_control`
## on respawn. Deliberately does not touch `GameState.mode`: whoever took the
## character away owns the mode, and overwriting it here would fight the pause menu.
func release_rider(_rider: Node) -> void:
	_active = false
	_velocity = Vector3.ZERO


## Leaving the free camera has to happen when something else takes over the session
## state — pausing, dying — otherwise the camera would stay `current` and render
## over the pause menu.
func _on_game_mode_changed(_previous: int, current_mode: int) -> void:
	if _active and current_mode != GameState.Mode.FREECAM:
		_active = false
		_velocity = Vector3.ZERO
		var player: Player = _resolve_player()
		if player != null:
			player.release_external_control()
			_return_view_to_player(player)


func _return_view_to_player(player: Player) -> void:
	if player.camera != null and is_instance_valid(player.camera):
		player.camera.current = true


## Resolved through the `player` group: this node is added by the boot sequence and
## may be created before or after the character depending on how the world is built.
func _resolve_player() -> Player:
	var tree: SceneTree = get_tree()
	if tree == null:
		return null
	return tree.get_first_node_in_group(&"player") as Player


func _apply_look() -> void:
	rotation = Vector3(_pitch, _yaw, 0.0)
