extends MapSource
class_name PlaygroundMapSource
## The classic open-the-game map: a flat lawn, a few white-box rooms to build
## in, a strip of water, and a wall around it all — assembled entirely from
## code, like everything else here.
##
## This is the second implementation of the `MapSource` seam, and its real job
## is to prove that seam honest: the boot flow, the spawn menu, the wrench, the
## tool gun and the build panel must work identically on a map with no dataset,
## no SDK and no place table. Citizens degrade to wandering (the mobility
## readiness report says exactly that), which is the designed behaviour, not a
## defect.

const GROUND_SIZE: float = 160.0
const WALL_HEIGHT: float = 6.0
const WALL_THICKNESS: float = 1.0

var _spawn_position: Vector3 = Vector3(0.0, 1.0, 0.0)


func build(world_root: Node3D, seed_value: int) -> bool:
	Events.world_generation_started.emit(seed_value)
	var progress := func(step: String, ratio: float) -> void:
		Events.world_generation_progress.emit(step, ratio)

	progress.call("铺设草地", 0.1)
	_build_ground(world_root)

	progress.call("搭建白盒房间", 0.4)
	_build_rooms(world_root)

	progress.call("注水", 0.6)
	_build_water(world_root)

	progress.call("立起围墙", 0.75)
	_build_walls(world_root)

	# Ground geometry is in the physics space now, so queries may answer.
	(Services.get_as(&"surface_query", &"SurfaceQuery") as SurfaceQuery).mark_ready()

	progress.call("构建天空与光照", 0.88)
	_build_environment(world_root)

	ModHost.notify_world_generate(world_root)

	progress.call("生成人流", 0.95)
	_build_crowd(world_root, seed_value)

	_spawn_position = _find_spawn_position()
	ModHost.notify_world_populate(world_root)

	progress.call("完成", 1.0)
	return true


func find_spawn_position() -> Vector3:
	return _spawn_position


func map_id() -> String:
	return "playground:1"


func describe() -> Dictionary:
	return {
		"city": "playground",
		"size": "%.0f m" % GROUND_SIZE,
		"place_table": "无（市民游荡）",
	}


## A flat slab of grass. Every prop spawned here lands on it, and the surface
## query reads it through the map physics layer like any other map's ground.
func _build_ground(world_root: Node3D) -> void:
	var ground := StaticBody3D.new()
	ground.name = "Ground"
	ground.collision_layer = 1 | SurfaceQuery.GROUND_MASK
	ground.collision_mask = 0
	var shape := CollisionShape3D.new()
	shape.name = "GroundShape"
	var box := BoxShape3D.new()
	box.size = Vector3(GROUND_SIZE, 2.0, GROUND_SIZE)
	shape.shape = box
	ground.add_child(shape)
	ground.position = Vector3(0.0, -1.0, 0.0)

	var visual := MeshInstance3D.new()
	visual.name = "Visual"
	var plane := BoxMesh.new()
	plane.size = Vector3(GROUND_SIZE, 2.0, GROUND_SIZE)
	visual.mesh = plane
	visual.material_override = _material(Color(0.36, 0.52, 0.28), 0.95)
	ground.add_child(visual)
	world_root.add_child(ground)


## Three white-box rooms with an open doorway each: something to build inside,
## something to walk through, and walls that read at a glance as "built here".
func _build_rooms(world_root: Node3D) -> void:
	_room(world_root, Vector3(-24.0, 0.0, -18.0), 0.0)
	_room(world_root, Vector3(20.0, 0.0, -22.0), 90.0)
	_room(world_root, Vector3(16.0, 0.0, 20.0), 200.0)
	# A couple of loose slabs to weld things to.
	_slab(world_root, Vector3(-6.0, 0.5, 14.0), Vector3(6.0, 1.0, 6.0), Color(0.62, 0.62, 0.6))
	_slab(world_root, Vector3(10.0, 0.5, 6.0), Vector3(4.0, 1.0, 4.0), Color(0.62, 0.62, 0.6))


func _room(parent: Node3D, at: Vector3, yaw_degrees: float) -> void:
	var room := Node3D.new()
	room.name = "Room"
	room.position = at
	room.rotation_degrees = Vector3(0.0, yaw_degrees, 0.0)
	parent.add_child(room)
	var wall_color := Color(0.86, 0.86, 0.84)
	var size := 8.0
	var height := 3.5
	# Four walls with a doorway gap in the front one, plus a roof slab.
	_wall(room, Vector3(0.0, height * 0.5, -size * 0.5), Vector3(size, height, 0.3), wall_color)
	_wall(room, Vector3(-size * 0.5, height * 0.5, 0.0), Vector3(0.3, height, size), wall_color)
	_wall(room, Vector3(size * 0.5, height * 0.5, 0.0), Vector3(0.3, height, size), wall_color)
	# Front wall in two pieces, leaving a 2 m doorway in the middle.
	var side := (size - 2.0) * 0.5
	_wall(room, Vector3(-(1.0 + side * 0.5), height * 0.5, size * 0.5), Vector3(side, height, 0.3), wall_color)
	_wall(room, Vector3(1.0 + side * 0.5, height * 0.5, size * 0.5), Vector3(side, height, 0.3), wall_color)
	_wall(room, Vector3(0.0, height + 0.15, 0.0), Vector3(size + 0.3, 0.3, size + 0.3), wall_color)


func _wall(parent: Node3D, at: Vector3, size: Vector3, color: Color) -> void:
	var wall := StaticBody3D.new()
	wall.collision_layer = 1 | SurfaceQuery.GROUND_MASK
	wall.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	wall.add_child(shape)
	var visual := MeshInstance3D.new()
	visual.mesh = BoxMesh.new()
	(visual.mesh as BoxMesh).size = size
	visual.material_override = _material(color, 0.9)
	wall.add_child(visual)
	wall.position = at
	parent.add_child(wall)


func _slab(parent: Node3D, at: Vector3, size: Vector3, color: Color) -> void:
	var slab := StaticBody3D.new()
	slab.collision_layer = 1 | SurfaceQuery.GROUND_MASK
	slab.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	slab.add_child(shape)
	var visual := MeshInstance3D.new()
	visual.mesh = BoxMesh.new()
	(visual.mesh as BoxMesh).size = size
	visual.material_override = _material(color, 0.9)
	slab.add_child(visual)
	slab.position = at
	parent.add_child(slab)


## A water strip along one edge: visual only for now (no swim logic), but it
## gives the lawn a horizon that is not just more grass.
func _build_water(world_root: Node3D) -> void:
	var water := MeshInstance3D.new()
	water.name = "Water"
	var plane := PlaneMesh.new()
	plane.size = Vector2(GROUND_SIZE * 0.9, 18.0)
	water.mesh = plane
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.2, 0.42, 0.6, 0.85)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.roughness = 0.15
	material.metallic = 0.3
	water.material_override = material
	water.position = Vector3(0.0, 0.06, GROUND_SIZE * 0.5 - 11.0)
	world_root.add_child(water)


## Four low walls around the lawn so props and vehicles stay in play.
func _build_walls(world_root: Node3D) -> void:
	var half: float = GROUND_SIZE * 0.5
	_boundary_wall(world_root, Vector3(0.0, WALL_HEIGHT * 0.5, -half - WALL_THICKNESS * 0.5), Vector3(GROUND_SIZE + WALL_THICKNESS * 2.0, WALL_HEIGHT, WALL_THICKNESS))
	_boundary_wall(world_root, Vector3(0.0, WALL_HEIGHT * 0.5, half + WALL_THICKNESS * 0.5), Vector3(GROUND_SIZE + WALL_THICKNESS * 2.0, WALL_HEIGHT, WALL_THICKNESS))
	_boundary_wall(world_root, Vector3(-half - WALL_THICKNESS * 0.5, WALL_HEIGHT * 0.5, 0.0), Vector3(WALL_THICKNESS, WALL_HEIGHT, GROUND_SIZE + WALL_THICKNESS * 2.0))
	_boundary_wall(world_root, Vector3(half + WALL_THICKNESS * 0.5, WALL_HEIGHT * 0.5, 0.0), Vector3(WALL_THICKNESS, WALL_HEIGHT, GROUND_SIZE + WALL_THICKNESS * 2.0))


func _boundary_wall(parent: Node3D, at: Vector3, size: Vector3) -> void:
	var wall := StaticBody3D.new()
	wall.collision_layer = 1 | SurfaceQuery.GROUND_MASK
	wall.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	wall.add_child(shape)
	var visual := MeshInstance3D.new()
	visual.mesh = BoxMesh.new()
	(visual.mesh as BoxMesh).size = size
	visual.material_override = _material(Color(0.5, 0.48, 0.45), 0.95)
	wall.add_child(visual)
	wall.position = at
	parent.add_child(wall)


## Sky and sun. Kept local to each map source on purpose: a city and a lawn
## want different moods, and sharing a "default sky" would couple map sources
## to a base class they do not otherwise need.
func _build_environment(world_root: Node3D) -> void:
	var environment := WorldEnvironment.new()
	environment.name = "Environment"
	var sky := Sky.new()
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.4, 0.58, 0.82)
	sky_material.sky_horizon_color = Color(0.76, 0.82, 0.86)
	sky_material.ground_bottom_color = Color(0.3, 0.32, 0.3)
	sky_material.ground_horizon_color = Color(0.76, 0.82, 0.86)
	sky.sky_material = sky_material
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.fog_enabled = true
	env.fog_density = 0.002
	env.fog_sky_affect = 0.0
	environment.environment = env
	world_root.add_child(environment)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-48.0, -35.0, 0.0)
	sun.light_energy = 1.1
	sun.light_color = Color(1.0, 0.98, 0.94)
	sun.shadow_enabled = true
	world_root.add_child(sun)


## A small wandering crowd: no place table exists on this map, so the mobility
## readiness report says the feature is off and citizens stroll instead — the
## designed degradation, visible on screen.
func _build_crowd(world_root: Node3D, seed_value: int) -> void:
	var spawner: PropSpawner = Services.get_as(&"prop_spawner", &"PropSpawner") as PropSpawner
	if spawner == null:
		return
	var container := Node3D.new()
	container.name = "Pedestrians"
	world_root.add_child(container)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("playground-crowd|%d" % seed_value)
	for index: int in 8:
		var angle: float = rng.randf() * TAU
		var distance: float = 6.0 + rng.randf() * 30.0
		var spot: Vector3 = Vector3(cos(angle) * distance, 0.6, sin(angle) * distance)
		var citizen := spawner.spawn_citizen(spot, seed_value + index)
		if citizen != null and citizen.get_parent() != container:
			citizen.get_parent().remove_child(citizen)
			container.add_child(citizen)


## The lawn centre is a legal standing spot by construction — flat, outdoors,
## clear of the rooms.
func _find_spawn_position() -> Vector3:
	return Vector3(0.0, 1.2, 0.0)


func _material(color: Color, roughness: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	return material
