extends VehicleBody3D
class_name Vehicle
## A drivable vehicle. Ported from `Pickup.gd` in
## craftablescience/godot-3d-sandbox, which is the one system in that prototype
## with no equivalent here — the island had no way to move faster than a sprint.
##
## What was kept: the driving model (separate engine / brake / reverse forces, a
## steering angle that eases toward its target at a fixed rate, keyboard-only input)
## and the enter/exit interaction. What was replaced: the Godot 3 `VehicleBody` API
## with `VehicleBody3D`, and the original's habit of reparenting the player into the
## cabin.
##
## Reparenting is the interesting mistake to avoid. A `CharacterBody3D` moved under
## a rigid body has its transform written by the parent while its own collider keeps
## resolving contacts against that same parent, so the driver either jitters or
## launches the car. Instead the rider keeps its place in the world and is *pinned*
## to a seat marker with its own physics suspended; `Player.take_control` owns the
## suspension so the vehicle does not need to know what a `Player` can do.
##
## Vehicle state is deliberately not serialised: like terrain and prop placement, a
## vehicle's pose is reproduced from the world rather than stored.

@export_group("Drivetrain")
## Force applied at the wheels at full throttle. Named `max_`-something because
## `VehicleBody3D.engine_force` is the *applied* value and is written every physics
## step — keeping one name for both is how a drivetrain ends up self-multiplying
## itself down to zero. The prototype used 1000.0 for a much lighter chassis; this
## is tuned against `mass` in `VehicleScene`.
@export var max_engine_force: float = 2400.0
@export var reverse_force: float = 900.0
@export var brake_force: float = 90.0
## Above this forward speed the throttle is cut, which is what stops the car
## accelerating forever on a downhill.
@export var max_speed: float = 26.0

@export_group("Steering")
@export var max_steer_angle: float = 0.45
## Radians per second the steering angle moves toward its target, so the wheels
## turn at a believable rate instead of snapping. Mirrors the prototype's
## `steer_speed` (0.6 rad/s there; faster here because the car is faster).
@export var steer_speed: float = 2.6
@export var steer_return_multiplier: float = 1.8

@export_group("Interaction")
@export var enter_verb: String = "上车"
@export var exit_verb: String = "下车"
## How far above the exit point the ground is sampled, so the driver is never
## dropped inside a slope when they get out.
@export var exit_ground_clearance: float = 0.6

var seats: Array[VehicleSeat] = []
var wheels: Array[VehicleWheel3D] = []

var seat: Node3D = null
var exit_point: Node3D = null

var _driver: Node3D = null
var _steer_angle: float = 0.0


func _ready() -> void:
	for child: Node in get_children():
		if child is VehicleWheel3D:
			wheels.append(child)
		elif child is VehicleSeat:
			seats.append(child)
	seat = get_node_or_null("Seat") as Node3D
	exit_point = get_node_or_null("ExitPoint") as Node3D
	for vehicle_seat: VehicleSeat in seats:
		vehicle_seat.vehicle = self

	if wheels.is_empty():
		push_warning("Vehicle '%s' has no VehicleWheel3D children; it will not drive" % name)


## Whether anyone is driving. The seat interaction reads this to choose its verb.
func is_occupied() -> bool:
	return _driver != null and is_instance_valid(_driver)


func driver() -> Node3D:
	return _driver


## Enter if free, leave if driven by this rider. One entry point for both halves
## because the seat is a single interactable, and a two-method API would have every
## caller re-deriving which half applies.
func toggle_occupant(rider: Node3D) -> bool:
	if is_occupied():
		if _driver == rider:
			exit_vehicle()
			return false
		return true
	return enter_vehicle(rider)


func enter_vehicle(rider: Node3D) -> bool:
	if rider == null or is_occupied():
		return false
	if not rider.has_method("take_control"):
		push_warning("Vehicle: %s cannot be driven — it has no take_control()" % rider.name)
		return false
	if not rider.call("take_control", self):
		return false
	_driver = rider
	Events.vehicle_entered.emit(self, rider)
	Events.notify("已上车 — WASD 驾驶 · E 下车", Events.NotifyLevel.INFO)
	return true


func exit_vehicle() -> void:
	if not is_occupied():
		return
	var rider: Node3D = _driver
	_driver = null
	if rider.has_method("release_external_control"):
		rider.call("release_external_control")
	_place_rider_on_exit(rider)
	# Cutting the throttle here matters: a car left at full throttle with nobody in
	# it is the classic way this kind of feature produces a runaway vehicle.
	engine_force = 0.0
	brake = brake_force
	Events.vehicle_exited.emit(self, rider)
	Events.notify("已下车", Events.NotifyLevel.INFO)


## `Player.release_external_control` calls this so a respawn or a mode change can
## take the character back without the vehicle believing it still has a driver.
func release_rider(rider: Node) -> void:
	if _driver != rider:
		return
	_driver = null
	engine_force = 0.0
	brake = brake_force
	Events.vehicle_exited.emit(self, rider)


func _physics_process(delta: float) -> void:
	if is_occupied():
		_drive(delta)
		_pin_rider()
	else:
		engine_force = 0.0
		# A parked vehicle is held still, but only lightly: full brake force would
		# make it unable to roll into its resting pose on a slope.
		brake = brake_force * 0.25


## Keyboard driving, kept close to the prototype's model: forward and reverse are
## separate forces, the brake is applied whenever the input opposes the current
## direction of travel, and steering eases toward its target.
func _drive(delta: float) -> void:
	var throttle: float = (
		Input.get_action_strength(&"move_forward") - Input.get_action_strength(&"move_back")
	)
	var steer_input: float = (
		Input.get_action_strength(&"move_left") - Input.get_action_strength(&"move_right")
	)

	# VehicleBody3D's forward is -Z, so the dot product gives signed forward speed.
	var forward: Vector3 = -global_transform.basis.z
	var forward_speed: float = forward.dot(linear_velocity)

	if throttle > 0.0:
		if forward_speed < -0.8:
			# Still rolling backwards: first input is a brake, not reverse.
			engine_force = 0.0
			brake = brake_force * throttle
		elif forward_speed < max_speed:
			engine_force = throttle * max_engine_force
			brake = 0.0
		else:
			engine_force = 0.0
			brake = 0.0
	elif throttle < 0.0:
		if forward_speed > 0.8:
			engine_force = 0.0
			brake = brake_force * -throttle
		elif forward_speed > -max_speed * 0.45:
			engine_force = throttle * reverse_force
			brake = 0.0
		else:
			engine_force = 0.0
			brake = 0.0
	else:
		engine_force = 0.0
		brake = 0.0

	var steer_target: float = steer_input * max_steer_angle
	# Returning to centre is faster than turning away from it, which is what makes a
	# car feel like it lets go of a corner rather than unwinding slowly.
	var rate: float = steer_speed
	if absf(steer_target) < absf(_steer_angle):
		rate *= steer_return_multiplier
	_steer_angle = move_toward(_steer_angle, steer_target, rate * delta)
	steering = _steer_angle


## The rider's transform is written here, from the seat marker, after the body has
## moved for this step. `Player`'s own physics is suspended, so this is the only
## writer and there is no tug of war.
func _pin_rider() -> void:
	if seat == null or _driver == null:
		return
	_driver.global_position = seat.global_position


## Put the driver down beside the car, on the ground rather than in it. Sampling the
## terrain is what keeps a driver who exits on a slope from spawning inside the hill.
func _place_rider_on_exit(rider: Node3D) -> void:
	if rider == null or not is_instance_valid(rider):
		return
	var target: Vector3 = (exit_point.global_position if exit_point != null else global_position)
	var query: TerrainQuery = Services.get_as(&"terrain_query", &"TerrainQuery") as TerrainQuery
	if query != null and query.is_ready():
		target = query.sample_height(Vector3(target.x, 0.0, target.z), exit_ground_clearance)
	rider.global_position = target
	# Zeroed explicitly rather than assumed already zero: `Player` suspends its own
	# physics while ridden, so nothing else clears the velocity this rider had when
	# it stepped in.
	if rider is CharacterBody3D:
		(rider as CharacterBody3D).velocity = Vector3.ZERO
	elif rider is RigidBody3D:
		(rider as RigidBody3D).linear_velocity = Vector3.ZERO


## Diagnostic snapshot used by the boot report, so a headless run can prove the
## vehicle was built with its wheels wired rather than merely instantiated.
func describe() -> String:
	var traction: int = 0
	var steering_wheels: int = 0
	for wheel: VehicleWheel3D in wheels:
		if wheel.use_as_traction:
			traction += 1
		if wheel.use_as_steering:
			steering_wheels += 1
	return "%s wheels=%d traction=%d steering=%d seats=%d occupied=%s" % [
		name, wheels.size(), traction, steering_wheels, seats.size(), is_occupied(),
	]
