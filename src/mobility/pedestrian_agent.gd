extends CharacterBody3D
class_name PedestrianAgent
## One person walking a resolved day: follows the polyline their `AgentRoute`
## provides, leg by leg, in the open world.
##
## Movement is deliberately unglamorous: walk toward the current waypoint and let
## `move_and_slide` do the avoidance. The city's buildings carry collision, so a
## straight leg that meets a wall *slides along it* instead of penetrating — the
## same trick the vehicle uses. A real path finder (SDK road network, navmesh)
## can replace the straight-line default later without touching this file: the
## route's `set_path_finder` injection point is the seam for that, and this class
## only consumes whatever polyline it is handed.
##
## Deliberately NOT persisted: like the vehicles, the crowd is regenerated from
## seed on load — a save stores decisions, and "person 7 was mid-block" is not a
## decision.

const WALK_SPEED: float = 1.4
## Within this distance of a waypoint, count it as reached and move to the next.
const ARRIVAL_DISTANCE: float = 0.9
## Turn rate is instant: at 1.4 m/s nobody reads a snappy rotation on a capsule.
const GRAVITY: float = 18.0

var route: AgentRoute = null

var _waypoints: PackedVector3Array = PackedVector3Array()
var _waypoint_index: int = 0


func _ready() -> void:
	_build_body()


## Resolve a day and start walking. Same parameters as `AgentRoute.configure`
## plus the path finder, so the caller wires one callable and nothing else.
func configure(
	activity_pattern: ActivityPattern,
	candidates: Array[Dictionary],
	cache: RouteCache,
	map_version: String,
	origin: Vector3,
	seed: int,
	home_key: StringName,
	path_finder: Callable,
) -> void:
	route = AgentRoute.new()
	route.set_path_finder(path_finder)
	route.configure(activity_pattern, candidates, cache, map_version, origin, seed, home_key)
	global_position = origin
	_refresh_waypoints()


func _physics_process(delta: float) -> void:
	if route == null or route.is_finished():
		# The day is over; stand still. People who finished their day are still
		# city content — they just stop being a moving target.
		if not is_on_floor():
			velocity.y -= GRAVITY * delta
			move_and_slide()
		return
	if not is_on_floor():
		velocity.y -= GRAVITY * delta

	var target: Vector3 = _current_waypoint()
	var to_target: Vector3 = target - global_position
	to_target.y = 0.0
	if to_target.length() < ARRIVAL_DISTANCE:
		_advance_waypoint()
	else:
		var direction: Vector3 = to_target.normalized()
		velocity.x = direction.x * WALK_SPEED
		velocity.z = direction.z * WALK_SPEED
		# Face the walk direction — a capsule with no facing reads as a sliding
		# cone, and one rotation line is the cheapest "this is a person" signal.
		look_at(global_position + direction, Vector3.UP)
	move_and_slide()


## Whether the agent got a usable day. Callers report the count of the other kind
## rather than spawning empty walkers.
func has_day() -> bool:
	return route != null and route.stop_count() > 0


func progress_fraction() -> float:
	if route == null:
		return 1.0
	return route.progress_fraction()


## One line for the boot report.
func describe() -> String:
	if route == null:
		return "pedestrian(no route)"
	return "pedestrian(%s)" % route.describe()


## The current leg's polyline, refreshed whenever the route advances a leg.
func _current_waypoint() -> Vector3:
	if _waypoint_index < _waypoints.size():
		return _waypoints[_waypoint_index]
	return route.current_target()


func _advance_waypoint() -> void:
	_waypoint_index += 1
	if _waypoint_index >= _waypoints.size():
		# The leg is walked; ask the route for the next one (which lazily resolves
		# that leg's path through the shared cache).
		if route.advance():
			_refresh_waypoints()


func _refresh_waypoints() -> void:
	_waypoints = route.current_path()
	# An empty path means the finder could not connect the places (or none was
	# supplied): fall back to walking the straight line to the stop itself.
	if _waypoints.is_empty():
		_waypoints = PackedVector3Array([route.current_target()])
	_waypoint_index = 0


## A capsule with a colour by resolved tag, so the crowd reads at a glance.
## Built in code like everything else in this project.
func _build_body() -> void:
	var shape := CollisionShape3D.new()
	shape.name = "Body"
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.28
	capsule.height = 1.5
	shape.shape = capsule
	shape.position = Vector3(0.0, 0.75, 0.0)
	add_child(shape)

	collision_layer = 1
	collision_mask = 1

	var mesh := MeshInstance3D.new()
	mesh.name = "Visual"
	var capsule_mesh := CapsuleMesh.new()
	capsule_mesh.radius = 0.26
	capsule_mesh.height = 1.5
	mesh.mesh = capsule_mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.85, 0.72, 0.55)
	material.roughness = 0.9
	mesh.material_override = material
	mesh.position = Vector3(0.0, 0.75, 0.0)
	add_child(mesh)
