extends Node3D
class_name CameraRig
## Orbit camera for the player. Yaw lives here, pitch lives on the spring arm's
## child pivot, so the character's facing can follow the camera without fighting
## the arm's collision response.

@export var target: Node3D = null
@export var mouse_sensitivity: float = 0.0026
## Vertical look starts inverted (flight-style: mouse up, look down). A toggle,
## not a layout decision — anything that flips an axis must be flippable back.
@export var invert_y: bool = true
@export var min_pitch_degrees: float = -70.0
@export var max_pitch_degrees: float = 62.0
@export var follow_lerp: float = 14.0
## Height above the character's origin that the camera orbits.
@export var pivot_height: float = 1.6
## Distance the spring arm tries to hold.
@export var arm_length: float = 5.4
@export var capture_mouse_on_start: bool = true

## Zoom limits for the wheel. Close enough to read a face, far enough to see the
## surroundings. First person is a separate toggle (F6), not the zoom's end stop —
## two controls that do different things should not be one control that surprises.
@export var min_arm_length: float = 1.2
@export var max_arm_length: float = 9.0
## How fast the camera's obstacle-shortened distance pulls IN (m/s). Fast on
## purpose — the pull-in is the safety direction, and a slow one lets the
## camera clip the surface it is avoiding.
@export var arm_pull_speed: float = 25.0
## How fast the camera's distance extends back out after an obstacle clears
## (m/s). Slower than the pull-in: the SpringArm3D's own placement snaps in
## and out in single ticks, and the snap-back read as a screen flash.
@export var arm_extend_speed: float = 7.0
@export var zoom_step: float = 0.6
## Metres of orbit height per pixel of a held-middle-button vertical drag.
@export var height_drag_step: float = 0.0035
## How far one press of 升高/降低 (T/G) moves the orbit height, and the range it is
## allowed to cover: high enough to look down at an outfit, low enough to frame a
## face from below.
@export var height_step: float = 0.35
@export var min_pivot_height: float = 0.4
@export var max_pivot_height: float = 3.2
## Handheld breathing: how far the camera drifts off its orbit while the figure
## moves (m). Zero would be a tripod; a small figure-wide drift is what makes a
## moving shot read as *held by a person* rather than bolted to a rail. The
## motion is two out-of-phase sines, not noise — noise flickers at low frame
## rates, sines just wobble.
@export var walk_bob_strength: float = 0.018
@export var walk_bob_speed: float = 8.2

var _bob_time: float = 0.0

var _pitch: float = -0.18
var _yaw: float = 0.0
var _arm_length: float = 5.4
## The camera's *displayed* distance — the user length eased toward the
## obstacle-limited one. The SpringArm3D still casts the full length every
## tick (its `get_hit_length` is the obstacle limit), but the camera itself
## is placed on this eased value, so avoidance pulls in fast and slides back
## instead of snapping both ways.
var _display_length: float = 5.4
## The Camera3D under the spring arm, resolved once in `_ready`.
var _camera: Camera3D = null
## The third-person distance to restore when first person ends.
var _saved_arm_length: float = 5.4
var _first_person: bool = false
## True while the middle button is held: vertical mouse motion drags the orbit
## height instead of turning the view.
var _height_drag: bool = false
## Lateral offset of the orbit centre, in camera-right metres. Zero in normal play;
## the wardrobe view uses it to hold the character left of the frame while the panel
## owns the right half of the screen.
var _pivot_offset: Vector3 = Vector3.ZERO
var _wardrobe: bool = false
var _saved_yaw: float = 0.0
var _saved_pitch: float = 0.0
var _saved_pivot_height: float = 0.0
var _saved_first_person: bool = false
var _spring_arm: SpringArm3D = null
var _pivot: Node3D = null
## The target's whole visual node (`Player/Visual`), hidden in first person — the
## camera sits inside the head at that point, and a face filling the screen is not
## a view, it is an obstruction. Resolved lazily: the rig is built before the
## target in some paths.
var _visual: Node3D = null
## The attached humanoid (`Player/PlayerModel`), when one exists. The capsule
## `Visual` is then only a fallback body, and this rig is the reason it must stay
## one: `_update_visual` used to reopen the capsule every tick, so the fallback
## re-emerged wrapped around the figure in every third-person view.
var _model: Node3D = null
## Whether the model lookup has landed. A null result is retried, because the
## model can be attached after the rig starts ticking (mod models load late).
var _model_resolved: bool = false

## The wardrobe framing: close enough to read a face and a hem, high enough not to
## look up anyone's nose, and offset so the character lands left of centre.
##
## The offset is the load-bearing number: the panel covers the right two-thirds of
## the screen, so the character has to sit ~34° off the view axis to clear it
## entirely — 0.9 m at this arm length only bought ~18° and the panel's left edge
## still covered the figure.
const WARDROBE_ARM_LENGTH: float = 2.6
const WARDROBE_PIVOT_HEIGHT: float = 1.15
const WARDROBE_SIDE_OFFSET: float = 1.7
const WARDROBE_PITCH_DEGREES: float = -5.0


func _ready() -> void:
	# Always-on is what keeps the wardrobe framing working: the panel pauses the
	# tree, and a paused SpringArm3D never repositions its camera child — the
	# framing would set an arm length the camera never reaches. The rig only moves
	# a camera, so running under a menu costs nothing; the view keys below yield
	# while the wardrobe owns the framing.
	process_mode = Node.PROCESS_MODE_ALWAYS
	# The rig already smooths its own position every rendered frame (the follow
	# lerp below); letting the engine interpolate it again would double-smooth
	# and lag the camera behind the interpolated character. Physics
	# interpolation (project setting) is for things the physics engine moves —
	# the character, props, citizens — not for a node driven by hand.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_spring_arm = get_node_or_null("SpringArm3D") as SpringArm3D
	if _spring_arm != null:
		_pivot = _spring_arm.get_parent() as Node3D
		_spring_arm.spring_length = arm_length
		_camera = _spring_arm.get_node_or_null("Camera3D") as Camera3D
	_arm_length = arm_length
	_display_length = arm_length
	# Decouple from the target's transform. As a plain child of the player the
	# rig inherited the *interpolated* player transform every rendered frame,
	# while the compensation it applied (`rotation.y = _yaw - body_yaw`) read
	# the body's raw 60 Hz physics yaw — during a turn the two disagreed by up
	# to one physics tick of rotation (≈9.5° at turn_speed 10), shaking the
	# camera's world-space heading every frame the body pivoted or stopped.
	# Top-level, the rig owns its world transform outright: yaw is written
	# directly and the follow lerp below already does all the position work.
	# The world yaw/position are captured before the toggle and re-applied
	# after, so the spawn placement survives the decoupling regardless of the
	# engine's toggle semantics.
	_yaw = global_rotation.y
	var spawn_position := global_position
	top_level = true
	global_position = spawn_position
	if capture_mouse_on_start:
		set_mouse_captured(true)


func _unhandled_input(event: InputEvent) -> void:
	# A controller that brings its own camera (the debug free camera) turns this
	# off, so one mouse motion cannot steer two cameras at once. Read dynamically
	# rather than through a `Player` reference: the rig must keep working for any
	# target that never heard of this property — a missing property reads as
	# enabled, and only an explicit false turns the view input off. (`bool(null)`
	# is not a valid constructor call here, so the truthiness check is direct.)
	if target != null:
		var look_enabled: Variant = target.get(&"look_input_enabled")
		if look_enabled != null and not look_enabled:
			return
	# The wardrobe owns the framing while it is open — the rig runs under the menu
	# (see `_ready`), and wheel/height/first-person presses would fight a view the
	# panel chose on purpose.
	if _wardrobe:
		return
	if event is InputEventMouseMotion:
		var motion: InputEventMouseMotion = event
		# A held middle button drags the orbit height, captured or not — the
		# windowed mouse (no capture) must be able to do it too. Dragging down
		# raises the camera: pulling the world downward. One sign flips the feel.
		if _height_drag:
			pivot_height = clampf(
				pivot_height + motion.relative.y * height_drag_step,
				min_pivot_height,
				max_pivot_height
			)
			return
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			return
		_yaw -= motion.relative.x * mouse_sensitivity
		var pitch_delta: float = motion.relative.y * mouse_sensitivity
		_pitch += -pitch_delta if invert_y else pitch_delta
		_pitch = clampf(
			_pitch,
			deg_to_rad(min_pitch_degrees),
			deg_to_rad(max_pitch_degrees)
		)
	elif event is InputEventMouseButton and event.is_pressed():
		# Wheel up pulls the camera in, wheel down pushes it out — the direction
		# every third-person game uses, so nobody has to think about it. The
		# middle button starts a height drag instead of zooming.
		var button: InputEventMouseButton = event
		if button.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom_in()
		elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom_out()
		elif button.button_index == MOUSE_BUTTON_MIDDLE:
			_height_drag = true
	elif event is InputEventMouseButton:
		# The release ends the drag even if the press happened elsewhere —
		# a lost press must not strand the rig in height-drag mode.
		if (event as InputEventMouseButton).button_index == MOUSE_BUTTON_MIDDLE:
			_height_drag = false
	elif event.is_action_pressed(&"camera_raise"):
		raise_pivot()
	elif event.is_action_pressed(&"camera_lower"):
		lower_pivot()
	elif event.is_action_pressed(&"first_person"):
		set_first_person(not _first_person)
	elif event.is_action_pressed(&"ui_cancel"):
		set_mouse_captured(Input.mouse_mode != Input.MOUSE_MODE_CAPTURED)


func _process(delta: float) -> void:
	if target == null or not is_instance_valid(target):
		return
	# The visual is resolved on the first tick rather than in `_ready`, because the
	# rig can be attached before its target's children exist.
	_update_visual()
	# Rotation first, so the lateral offset below is expressed against this frame's
	# basis rather than the previous one's. The rig holds a *world* heading (it is
	# top-level — see `_ready`): the body turns to face where it walks
	# (`Player._update_facing`), and the view keeps its heading while the body
	# pivots under it.
	rotation.y = _yaw
	if _pivot != null:
		_pivot.rotation.x = _pitch
	# The lateral offset is taken against the camera's current right, so the
	# character stays on their side of the frame at any yaw. In first person the
	# pivot also steps forward along the view: the eye sits in front of the
	# body's axis, which is what makes looking down show chest and feet instead
	# of the near plane slicing the torso open.
	var right: Vector3 = global_transform.basis.x
	var forward: Vector3 = -global_transform.basis.z
	var desired: Vector3 = target.global_position \
		+ Vector3.UP * pivot_height + right * _pivot_offset.x \
		+ forward * _eye_forward()
	# Handheld drift: two out-of-phase sines scaled by the figure's planar
	# speed — a tripod when still, breathing the most at a sprint. Sines rather
	# than noise because noise flickers at low frame rates; sines just wobble.
	var planar: float = Vector2(target.velocity.x, target.velocity.z).length() \
		if target is Player else 0.0
	var bob: float = walk_bob_strength * clampf(planar / 8.6, 0.0, 1.0)
	_bob_time += delta
	desired += right * sin(_bob_time * walk_bob_speed) * bob \
		+ Vector3.UP * sin(_bob_time * walk_bob_speed * 1.7 + 1.3) * bob * 0.6
	global_position = global_position.lerp(desired, clampf(follow_lerp * delta, 0.0, 1.0))
	_update_camera_distance(delta)


func set_mouse_captured(captured: bool) -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if captured else Input.MOUSE_MODE_VISIBLE
	if not captured:
		GameState.mode = GameState.Mode.PAUSED


func yaw() -> float:
	return _yaw


## Wheel in: the camera comes closer. Clamped — the near stop is a close third
## person, not first person, which has its own explicit toggle. Ignored while first
## person is on: the wheel must not fight the toggle by moving a spring arm the
## player cannot see.
func zoom_in() -> void:
	if _first_person:
		return
	_set_arm_length(_arm_length - zoom_step)


## Wheel out: the camera pulls back.
func zoom_out() -> void:
	if _first_person:
		return
	_set_arm_length(_arm_length + zoom_step)


## T: the orbit centre rises, so the camera looks further down over the character.
func raise_pivot() -> void:
	pivot_height = clampf(pivot_height + height_step, min_pivot_height, max_pivot_height)


## G: the orbit centre drops.
func lower_pivot() -> void:
	pivot_height = clampf(pivot_height - height_step, min_pivot_height, max_pivot_height)


## F6: the camera moves onto the eye and the body is hidden.
##
## The saved distance is restored on the way out, so toggling first person does not
## throw away whatever the wheel had been set to.
func set_first_person(on: bool) -> void:
	if _first_person == on:
		return
	_first_person = on
	if on:
		_saved_arm_length = _arm_length
		_apply_arm(0.0)
	else:
		_apply_arm(_saved_arm_length)
	_update_visual()
	_apply_first_person_view(on)


func is_first_person() -> bool:
	return _first_person


## The view's world yaw. `Player` reads it so the body can follow the view in
## first person; the rig itself holds a *world* heading (see `_process`), which
## is exactly what the caller wants here.
func get_view_yaw() -> float:
	return _yaw


func _set_arm_length(value: float) -> void:
	_arm_length = clampf(value, min_arm_length, max_arm_length)
	_apply_arm(_arm_length)


func _apply_arm(length: float) -> void:
	if _spring_arm != null:
		_spring_arm.spring_length = length


## Place the camera on an **eased** distance instead of the SpringArm3D's
## single-tick snap. The arm still does the sensing: it casts the full user
## length every physics tick and `get_hit_length` reports the obstacle limit.
## This function eases the displayed length toward that limit — pull-in at
## `arm_pull_speed` (safety first), release at the gentler
## `arm_extend_speed` — and writes the camera's local Z itself, overriding
## the arm's own placement before the frame renders.
func _update_camera_distance(delta: float) -> void:
	if _spring_arm == null or _camera == null:
		return
	var limit: float = minf(_arm_length, _spring_arm.get_hit_length())
	var rate: float = arm_pull_speed if limit < _display_length else arm_extend_speed
	_display_length = move_toward(_display_length, limit, rate * delta)
	_camera.position = Vector3(0.0, 0.0, _display_length)


func _update_visual() -> void:
	if _visual == null or not is_instance_valid(_visual):
		if target != null and is_instance_valid(target):
			_visual = target.get_node_or_null("Visual") as Node3D
	# The model can attach after the rig starts ticking (mod models load late), so
	# a miss is retried rather than cached as "no model" — but a landed lookup is
	# never re-walked, or the resolution cost would ride on every frame.
	if not _model_resolved:
		if target != null and is_instance_valid(target):
			_model = target.get_node_or_null("PlayerModel") as Node3D
			_model_resolved = _model != null and is_instance_valid(_model)
	var has_model: bool = _model != null and is_instance_valid(_model)
	if _visual != null:
		# With a model attached the capsule is a fallback body, not a second one:
		# it stays hidden in every view, or this line re-opens it each tick and the
		# capsule re-emerges wrapped around the figure (the wardrobe-view bug).
		# Without a model the capsule IS the body, so first person hides it —
		# the camera sits inside it.
		_visual.visible = not _first_person and not has_model
	if has_model:
		# The figure stays visible in first person on purpose — looking down must
		# show you yourself. Only the head meshes hide, once, in
		# `_apply_first_person_view`; this per-tick line only guards the whole.
		_model.visible = true


## Name parts whose meshes hide in first person, matched case-insensitively as
## substrings — no fixed list, so a mod-provided model hides its head the same
## way. `_ear` keeps the underscore so "sportswear" cannot match; a name that
## slips through is a cosmetic leak, never a crash.
const FP_HIDDEN_MESH_PARTS: PackedStringArray = [
	"head", "hair", "face", "eye", "brow", "lash", "_ear", "ahoge",
	"glass", "hat", "helm", "mask",
]


## How far in front of the body's axis the first-person eye sits (m). Real eyes
## are on the face, not on the spine: with the camera left on the axis, looking
## down puts the near plane *through* the torso — you see an interior rather than
## your own chest. A hand's width forward lands the view where a person's does:
## above the chest, looking down at it. Measured in play rather than guessed: at
## 0.14 the camera still sat close enough to the chest that the near plane would
## clip into it at some angles, so the offset was widened again.
const FIRST_PERSON_FORWARD: float = 0.24
## The same, at full sprint: the run cycle leans the torso (and the neck with
## it) forward, so a fixed offset leaves the eye behind the neck — "you see the
## back of your own neck while running". Sliding the eye forward with speed
## keeps it at the face the body is carrying.
const FIRST_PERSON_FORWARD_RUN: float = 0.46
## Speed at which the running offset is reached (the sprint speed).
const FIRST_PERSON_FORWARD_REF_SPEED: float = 8.6
## Kept clear of anything the forward step would otherwise touch (m).
const FORWARD_MARGIN: float = 0.06

## The layer that *only* the first-person camera hides. The figure's head meshes
## are tagged with it, and stay on the default layer as well, so every other
## observer keeps seeing them: the third-person view, photo mode — and, when
## multiplayer arrives, other players' cameras (each will need its own such
## layer once it has a first-person view of its own; one local player means one
## layer today).
const FP_HEAD_LAYER: int = 20


func _apply_first_person_view(on: bool) -> void:
	# Hiding is a property of *this view*, achieved by camera culling rather than
	# by making meshes invisible: `visible = false` hides the head from every
	# renderer — the third-person view after switching back, photo mode, and
	# other players — which is not what "first person" means. Tagging the head
	# meshes with `FP_HEAD_LAYER` and cutting that layer from this camera leaves
	# every other observer untouched.
	var cam: Camera3D = null
	if _spring_arm != null:
		cam = _spring_arm.get_node_or_null("Camera3D") as Camera3D
	if cam != null:
		cam.set_cull_mask_value(FP_HEAD_LAYER, not on)
	if _model == null or not is_instance_valid(_model):
		return
	for node: Node in _model.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		var lower := String(mesh.name).to_lower()
		for part: String in FP_HIDDEN_MESH_PARTS:
			if part in lower:
				# Permanent and idempotent: the tag is what lets the camera hide
				# it, and re-tagging on the next toggle must not double up.
				mesh.set_layer_mask_value(FP_HEAD_LAYER, true)
				break


## The first-person eye offset for this frame: fixed while standing, stretched
## forward as the figure speeds up (see `FIRST_PERSON_FORWARD_RUN`), and
## **shortened when geometry is in the way** — a fixed offset walks the camera
## into walls, which is the "the picture clips through the world" that shows up
## the moment the player stands close to anything.
func _eye_forward() -> float:
	if not _first_person:
		return 0.0
	var body_speed: float = 0.0
	if target is Player:
		body_speed = (target as Player).speed
	var t: float = clampf(body_speed / FIRST_PERSON_FORWARD_REF_SPEED, 0.0, 1.0)
	var wanted: float = lerpf(FIRST_PERSON_FORWARD, FIRST_PERSON_FORWARD_RUN, t)
	return minf(wanted, _clearance_ahead(wanted))


## How far the eye may step forward before it would touch geometry, clamped at
## zero. The eye stays inside the character's own capsule either way; this is
## about the *world* it walks up to.
func _clearance_ahead(wanted: float) -> float:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if space == null:
		return wanted
	var from: Vector3 = global_position
	var to: Vector3 = from + (-global_transform.basis.z) * (wanted + FORWARD_MARGIN)
	var query := PhysicsRayQueryParameters3D.create(from, to, 1)
	if target is CollisionObject3D:
		query.exclude = [(target as CollisionObject3D).get_rid()]
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return wanted
	var distance: float = from.distance_to(hit.get("position", from))
	return maxf(distance - FORWARD_MARGIN, 0.0)


## The wardrobe view: third person, from the front, the character held left of the
## frame so the panel on the right does not cover what is being adjusted.
##
## Applied **synchronously**: the panel pauses the tree while it is open, so this
## cannot wait for `_process` — and it should not, because the player is looking at
## the framing the instant the panel appears. Everything it changes is remembered
## and put back when it ends, including whether the camera was in first person and
## whatever distance the wheel had been set to.
func set_wardrobe_framing(on: bool) -> void:
	if _wardrobe == on:
		return
	_wardrobe = on
	# A height drag must not survive into a view the panel owns: its release
	# event is swallowed by the wardrobe's early return in `_unhandled_input`.
	_height_drag = false
	if on:
		_saved_yaw = _yaw
		_saved_pitch = _pitch
		_saved_pivot_height = pivot_height
		_saved_first_person = _first_person
		# Only third person owns a wheel distance; first person has already parked
		# its own in `_saved_arm_length`, and overwriting it here would lose it.
		if not _first_person:
			_saved_arm_length = _arm_length
		set_first_person(false)
		# The character faces away from the old camera, so the opposite yaw is the
		# front — the only view that can actually see the outfit being changed.
		_yaw = wrapf(_saved_yaw + PI, -PI, PI)
		_pitch = deg_to_rad(WARDROBE_PITCH_DEGREES)
		pivot_height = WARDROBE_PIVOT_HEIGHT
		_set_arm_length(WARDROBE_ARM_LENGTH)
		# Positive is camera-right, and aiming right of the character is what puts
		# the character on the left of the screen.
		_pivot_offset = Vector3(WARDROBE_SIDE_OFFSET, 0.0, 0.0)
	else:
		_yaw = _saved_yaw
		_pitch = _saved_pitch
		pivot_height = _saved_pivot_height
		_pivot_offset = Vector3.ZERO
		_set_arm_length(_saved_arm_length)
		set_first_person(_saved_first_person)
	_apply_now()


## The wardrobe transform, in one frame. `_process` would apply the same state on
## the next tick (the rig runs under the menu), but the first frame the panel is
## up must already be framed — and the SpringArm3D repositions its camera child in
## its own step, so the arm's length is applied to the camera **by hand** here.
func _apply_now() -> void:
	# Top-level (see `_ready`): `_yaw` is already a world heading.
	rotation.y = _yaw
	if _pivot != null:
		_pivot.rotation.x = _pitch
	if _spring_arm != null:
		# The wardrobe framing is deliberate: snap the displayed length to the
		# requested one instead of easing through the figure.
		_display_length = _arm_length
		if _camera == null:
			_camera = _spring_arm.get_node_or_null("Camera3D") as Camera3D
		if _camera != null:
			# The arm's tip in world space. Collision shortening is skipped on
			# this one placement; the arm re-syncs on the next tick it
			# processes.
			_camera.global_position = _spring_arm.global_transform \
				* Vector3(0.0, 0.0, _display_length)
	if target != null and is_instance_valid(target):
		var right: Vector3 = global_transform.basis.x
		var forward: Vector3 = -global_transform.basis.z
		global_position = target.global_position \
			+ Vector3.UP * pivot_height + right * _pivot_offset.x \
			+ forward * _eye_forward()
