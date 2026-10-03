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
## Wander mode picks targets inside this radius of the spawn point.
const WANDER_RADIUS: float = 30.0
## Seconds a fallen citizen stays before the world takes them back.
const CORPSE_LINGER: float = 4.0
## The shared base figure every citizen wears (the same `.vrm` the player
## wears). One PackedScene on disk, N instances in the world: shape-key
## weights and garment visibility are per-instance state, so a citizen is a
## *parameter set*, not a model. Absent or not yet imported → the capsule
## stays, silently.
const BASE_FIGURE_SCENE: String = "res://assets/characters/base_female.vrm"

var route: AgentRoute = null
## True when no annotated places were available: the citizen still walks, just
## without a day plan — random nearby targets instead of a commute.
var wandering: bool = false
## The seed this citizen's look was drawn from. Deterministic per citizen: the
## crowd reads as "forty pre-tuned people" and rebuilds identically from seed.
var figure_seed: int = 0

var _waypoints: PackedVector3Array = PackedVector3Array()
var _waypoint_index: int = 0
var _wander_rng := RandomNumberGenerator.new()
var _health: HealthComponent = null
var _dead: bool = false
## The dressed figure (null while on the capsule fallback).
var figure: Node3D = null
## The E-handle on this citizen; disabled on death.
var figure_editor: NpcFigureEditor = null


func _ready() -> void:
	add_to_group(&"citizens")
	_build_body()
	_build_health()


func _build_health() -> void:
	_health = HealthComponent.new()
	_health.name = "Health"
	_health.max_health = 60.0
	_health.current_health = 60.0
	add_child(_health)
	_health.defeated.connect(_on_defeated)


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
	wandering = false
	route = AgentRoute.new()
	route.set_path_finder(path_finder)
	route.configure(activity_pattern, candidates, cache, map_version, origin, seed, home_key)
	figure_seed = seed
	global_position = origin
	_refresh_waypoints()


## Walk free-form: no annotated places needed, so this is the degradation a
## menu-spawned citizen uses on any map. Same body, same movement code.
func configure_wander(origin: Vector3, seed: int) -> void:
	wandering = true
	route = null
	figure_seed = seed
	global_position = origin
	_wander_rng.seed = hash("wander|%s|%d" % [origin, seed])
	_refresh_waypoints()


## Swap the capsule for the shared base figure. The whole appearance half —
## instantiation, component stack, seeded look, journaled overrides, on-demand
## rendering, the edit handle — lives in `NpcFigure.dress_agent`; the agent
## keeps only movement, simulation and health. Returns false when the figure
## asset is unavailable — the caller keeps the capsule and nothing else changes.
func apply_base_figure() -> bool:
	return NpcFigure.dress_agent(self)


func _physics_process(delta: float) -> void:
	if _dead:
		return
	if route == null or route.is_finished():
		if wandering:
			_pick_wander_target()
		elif not is_on_floor():
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
		return 0.0
	return route.progress_fraction()


## One line for the boot report.
func describe() -> String:
	if _dead:
		return "citizen(dead)"
	if wandering:
		return "citizen(wandering)"
	if route == null:
		return "citizen(no route)"
	return "citizen(%s)" % route.describe()


## The current leg's polyline, refreshed whenever the route advances a leg.
func _current_waypoint() -> Vector3:
	if _waypoint_index < _waypoints.size():
		return _waypoints[_waypoint_index]
	return route.current_target()


func _advance_waypoint() -> void:
	_waypoint_index += 1
	if _waypoint_index >= _waypoints.size():
		# The leg is walked; ask the route for the next one (which lazily resolves
		# that leg's path through the shared cache). A wanderer has no route and
		# simply picks a new nearby target.
		if route != null:
			if route.advance():
				_refresh_waypoints()
		elif wandering:
			_pick_wander_target()


func _refresh_waypoints() -> void:
	_waypoints = route.current_path() if route != null else PackedVector3Array()
	# An empty path means the finder could not connect the places (or none was
	# supplied): fall back to walking the straight line to the stop itself.
	if _waypoints.is_empty():
		_waypoints = PackedVector3Array([route.current_target() if route != null else global_position])
	_waypoint_index = 0


func _pick_wander_target() -> void:
	var angle: float = _wander_rng.randf() * TAU
	var distance: float = 4.0 + _wander_rng.randf() * WANDER_RADIUS
	_waypoints = PackedVector3Array([global_position + Vector3(cos(angle) * distance, 0.0, sin(angle) * distance)])
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


## Death: fall over, stop being physics-active, and let the world take the
## body back. No gore, no ragdoll — a figure (or capsule) tipped on its side
## reads clearly.
func _on_defeated(_killer: Node) -> void:
	if _dead:
		return
	_dead = true
	collision_layer = 0
	collision_mask = 0
	velocity = Vector3.ZERO
	if figure_editor != null:
		figure_editor.enabled = false
	if figure != null:
		figure.rotation_degrees = Vector3(90.0, figure.rotation_degrees.y, 0.0)
		figure.position = Vector3(0.0, 0.3, 0.0)
	else:
		var visual := get_node_or_null("Visual") as MeshInstance3D
		if visual != null:
			visual.rotation_degrees = Vector3(90.0, 0.0, 0.0)
			visual.position = Vector3(0.0, 0.3, 0.0)
	Events.notify("一位市民倒下了", Events.NotifyLevel.WARNING)
	var timer := get_tree().create_timer(CORPSE_LINGER)
	timer.timeout.connect(func() -> void:
		if is_instance_valid(self):
			queue_free()
	)
