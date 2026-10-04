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

## The pond dug into the far edge of the lawn. These four numbers are the whole
## geometry contract: the lawn is laid out as "everything except this rectangle",
## and the water surface sits one lip below the grass so the bank reads as a bank.
const POOL_LENGTH: float = 18.0
const POOL_DEPTH: float = 2.0
## Dry grass left between the pond and the boundary wall, and at either end.
const POOL_BACK_EDGE: float = 2.0
const POOL_SIDE_EDGE: float = 8.0
## Water level relative to the lawn surface: slightly below it, so there is a
## visible lip rather than a surface that z-fights with the grass it floods.
const WATER_LEVEL: float = -0.12

const WATER_SHADER: Shader = preload("res://assets/shaders/water.gdshader")

## The lawn's sound. CC0 recordings from BigSoundBank — see
## `assets/audio/LICENSE_SOURCES.md` for provenance and what was done to them.
## Loading a `.ogg` rather than an `.mp3` is deliberate: MP3 encoder padding breaks
## gapless looping, and these are loops.
const BED_FOREST: AudioStream = preload("res://assets/audio/ambience_forest.ogg")
const BED_NIGHT: AudioStream = preload("res://assets/audio/ambience_night.ogg")
const WATER_STREAM: AudioStream = preload("res://assets/audio/water_stream.ogg")

## Which `DemoLook` preset this map was built with, reported by `describe()`.
var _look_preset: StringName = DemoLook.DEFAULT_PRESET

## What `_build_decor` ended up placing, reported by `describe()`. The requested
## counts and the resulting ones are allowed to differ — rejection sampling
## declines a spot it cannot find rather than forcing one into a wall — so the
## report carries what actually landed, not what was asked for.
var _decor_counts: Dictionary = {}

## How many citizens the last `_build_crowd` put on the lawn, for `describe()`.
var _crowd_size: int = 0

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

	progress.call("摆放树木与灯柱", 0.84)
	_decor_counts = _build_decor(world_root, seed_value)

	progress.call("构建天空与光照", 0.88)
	_build_environment(world_root)

	progress.call("铺上环境音", 0.9)
	_build_ambience(world_root)

	ModHost.notify_world_generate(world_root)

	progress.call("生成人流", 0.95)
	_build_crowd(world_root, seed_value)

	_spawn_position = _find_spawn_position()
	ModHost.notify_world_populate(world_root)

	progress.call("完成", 1.0)
	return true


func find_spawn_position() -> Vector3:
	return _spawn_position


## The declared identity comes from the base class (`core:playground@1`) — the lawn
## has no dataset to drift, so it overrides nothing about identity.

func describe() -> Dictionary:
	return {
		"city": "playground",
		"size": "%.0f m" % GROUND_SIZE,
		"place_table": "无（市民游荡）",
		"decor": "树 %d · 灯 %d · 椅 %d · 石 %d · 花 %d" % [
			int(_decor_counts.get("trees", 0)),
			int(_decor_counts.get("lanterns", 0)),
			int(_decor_counts.get("benches", 0)),
			int(_decor_counts.get("path_slabs", 0)),
			int(_decor_counts.get("flowers", 0)),
		],
		"look": "%s / %s" % [_look_preset, DemoLook.label(_look_preset)],
		# Asked for and actually built are reported separately: if the figure asset
		# is missing, `dressing` says "0 人" while `crowd` still says "vrm", and the
		# disagreement is the diagnostic.
		"crowd": "%d 人 · 外观 %s" % [_crowd_size, NpcFigure.default_appearance()],
		"dressing": NpcFigure.cost_report(),
	}


## The lawn, and the pond dug into one end of it. Every prop spawned here lands
## on it, and the surface query reads it through the map physics layer like any
## other map's ground.
##
## The pond is a real basin — banks on three sides and a floor two metres down —
## rather than a plane laid over the grass, because the water shader grades its
## colour and opacity by how much water is between the surface and whatever the
## depth buffer holds. Laid flat on grass there would be no water under it to
## see, and the whole pond would render as blue paint.
##
## The largest piece keeps the name `Ground`: the self-test asserts a playground
## has ground, and swapping that name for "the north lawn" would break a test for
## a reason no reader could guess.
func _build_ground(world_root: Node3D) -> void:
	var half: float = GROUND_SIZE * 0.5
	var pool_half_width: float = half - POOL_SIDE_EDGE
	var pool_near: float = half - POOL_BACK_EDGE - POOL_LENGTH
	var pool_far: float = half - POOL_BACK_EDGE
	var pool_centre_z: float = (pool_near + pool_far) * 0.5

	var grass := Color(0.36, 0.52, 0.28)
	# The lawn, front of the pond: z from -half to pool_near.
	_static_box(world_root, "Ground",
		Vector3(0.0, -1.0, (-half + pool_near) * 0.5),
		Vector3(GROUND_SIZE, 2.0, pool_near + half), grass, 0.95)
	# Banks either side of the pond, and the strip behind it.
	_static_box(world_root, "BankWest",
		Vector3((-half + -pool_half_width) * 0.5, -1.0, pool_centre_z),
		Vector3(POOL_SIDE_EDGE, 2.0, POOL_LENGTH), grass, 0.95)
	_static_box(world_root, "BankEast",
		Vector3((half + pool_half_width) * 0.5, -1.0, pool_centre_z),
		Vector3(POOL_SIDE_EDGE, 2.0, POOL_LENGTH), grass, 0.95)
	_static_box(world_root, "BankBack",
		Vector3(0.0, -1.0, (pool_far + half) * 0.5),
		Vector3(GROUND_SIZE, 2.0, half - pool_far), grass, 0.95)
	# The pond floor: its top face is POOL_DEPTH below the lawn, and the banks'
	# inner faces close the sides, so the basin needs no separate retaining walls.
	_static_box(world_root, "PondFloor",
		Vector3(0.0, -POOL_DEPTH - 1.0, pool_centre_z),
		Vector3(pool_half_width * 2.0, 2.0, POOL_LENGTH),
		Color(0.30, 0.29, 0.23), 0.98)


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
	_static_box(parent, "Wall", at, size, color, 0.9)


func _slab(parent: Node3D, at: Vector3, size: Vector3, color: Color) -> void:
	_static_box(parent, "Slab", at, size, color, 0.9)


## One static, collidable box with a plain colour: the unit this whole map is
## built from. Collision so props and players stand on it, the ground mask so the
## surface query finds it, and nothing else notable — this map is a backdrop for
## the sandbox, not a level with secrets in it.
func _static_box(parent: Node3D, box_name: String, at: Vector3, size: Vector3, color: Color, roughness: float) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = box_name
	body.collision_layer = 1 | SurfaceQuery.GROUND_MASK
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	var visual := MeshInstance3D.new()
	visual.name = "Visual"
	var mesh := BoxMesh.new()
	mesh.size = size
	visual.mesh = mesh
	visual.material_override = _material(color, roughness)
	body.add_child(visual)
	body.position = at
	parent.add_child(body)
	return body


## The pond surface: a subdivided plane carrying `water.gdshader`, which wants
## vertices to displace for its waves and the opaque depth buffer for its colour
## gradient. Deliberately a little larger than the basin so no sliver of floor
## shows along the waterline — the overhang is buried inside the banks.
func _build_water(world_root: Node3D) -> void:
	var half: float = GROUND_SIZE * 0.5
	var pool_half_width: float = half - POOL_SIDE_EDGE
	var pool_centre_z: float = half - POOL_BACK_EDGE - POOL_LENGTH * 0.5
	var size := Vector2(pool_half_width * 2.0 + 0.6, POOL_LENGTH + 0.6)

	var water := MeshInstance3D.new()
	water.name = "Water"
	var plane := PlaneMesh.new()
	plane.size = size
	# One-metre quads: the wave field's shortest octave is under three metres, so
	# anything coarser would sample the displacement below its own Nyquist rate
	# and put the aliasing straight into the silhouette.
	plane.subdivide_width = int(size.x)
	plane.subdivide_depth = int(size.y)
	water.mesh = plane
	# A transparent surface still casts a shadow by default, which would throw a
	# hard rectangle of shade onto the pond floor the water is meant to reveal.
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := ShaderMaterial.new()
	material.shader = WATER_SHADER
	water.material_override = material
	water.position = Vector3(0.0, WATER_LEVEL, pool_centre_z)
	world_root.add_child(water)


## Four low walls around the lawn so props and vehicles stay in play.
func _build_walls(world_root: Node3D) -> void:
	var half: float = GROUND_SIZE * 0.5
	_boundary_wall(world_root, Vector3(0.0, WALL_HEIGHT * 0.5, -half - WALL_THICKNESS * 0.5), Vector3(GROUND_SIZE + WALL_THICKNESS * 2.0, WALL_HEIGHT, WALL_THICKNESS))
	_boundary_wall(world_root, Vector3(0.0, WALL_HEIGHT * 0.5, half + WALL_THICKNESS * 0.5), Vector3(GROUND_SIZE + WALL_THICKNESS * 2.0, WALL_HEIGHT, WALL_THICKNESS))
	_boundary_wall(world_root, Vector3(-half - WALL_THICKNESS * 0.5, WALL_HEIGHT * 0.5, 0.0), Vector3(WALL_THICKNESS, WALL_HEIGHT, GROUND_SIZE + WALL_THICKNESS * 2.0))
	_boundary_wall(world_root, Vector3(half + WALL_THICKNESS * 0.5, WALL_HEIGHT * 0.5, 0.0), Vector3(WALL_THICKNESS, WALL_HEIGHT, GROUND_SIZE + WALL_THICKNESS * 2.0))


func _boundary_wall(parent: Node3D, at: Vector3, size: Vector3) -> void:
	_static_box(parent, "BoundaryWall", at, size, Color(0.5, 0.48, 0.45), 0.95)


## Sky, sun and the whole post-processing stack — all of it from the demo's
## shared baseline.
##
## The mood is still this map's own choice (`DemoLook` is opt-in, and the city
## asks for a different preset), but exposure, bloom, fog and the shadow cascade
## are now tuned in one place. That is the whole point: two screenshots of two
## maps should read as two places in one game, not as two projects.
func _build_environment(world_root: Node3D) -> void:
	_look_preset = &"day"
	DemoLook.apply(world_root, _look_preset)


## The lawn's sound: a forest bed that becomes a night bed when the light does, and
## a stream at the pond.
##
## Silent when the ambience service is absent. The headless tests build this map
## with no audio module at all, and a map that insisted on sound would turn a
## supported configuration into a failure — the same rule the rest of the optional
## modules follow.
##
## No `city` bed is listed, so the preset falls through to `default`: a lawn does
## not become a city, and the fallback is what keeps the mapping table short
## instead of exhaustive.
func _build_ambience(_world_root: Node3D) -> void:
	var ambience: Ambience = Services.get_as(&"ambience", &"Ambience") as Ambience
	if ambience == null:
		return
	ambience.set_beds({&"default": BED_FOREST, &"dusk": BED_NIGHT}, _look_preset)
	# The stream is placed where the water is, so it fades in as the pond comes into
	# earshot rather than being a global layer.
	var half: float = GROUND_SIZE * 0.5
	var pool_centre_z: float = half - POOL_BACK_EDGE - POOL_LENGTH * 0.5
	ambience.attach_point(WATER_STREAM, Vector3(0.0, WATER_LEVEL, pool_centre_z), 40.0, 10.0)


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
	_crowd_size = 0
	for index: int in 8:
		var angle: float = rng.randf() * TAU
		var distance: float = 6.0 + rng.randf() * 30.0
		var spot: Vector3 = Vector3(cos(angle) * distance, 0.6, sin(angle) * distance)
		var citizen := spawner.spawn_citizen(spot, seed_value + index)
		if citizen != null and citizen.get_parent() != container:
			citizen.get_parent().remove_child(citizen)
			container.add_child(citizen)
		if citizen != null:
			_crowd_size += 1


## The lawn's furniture: a stone path from the spawn down to the pond, lanterns
## and benches along it, trees around the edges, and flowers on the near bank.
##
## Laid out from the map seed, so the same seed always produces the same scene —
## which is what lets the layout be a *rule* instead of a saved file. Each piece
## comes from `Decor`; what lives here is the ground plan: which zones exist and
## what counts as occupied. Those are facts about this map, and putting them in
## `Decor` would be a second copy of the layout that could drift from this one.
##
## Reserved rectangles are in XZ and cover the pond basin, the three rooms, the two
## loose slabs and the path corridor. A scatter that lands in one is rejected — the
## pond band is the zone where that actually bites, since it reaches across the
## water on purpose.
func _build_decor(world_root: Node3D, seed_value: int) -> Dictionary:
	var decor := Node3D.new()
	decor.name = "Decor"
	world_root.add_child(decor)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("playground-decor|%d" % seed_value)

	var half: float = GROUND_SIZE * 0.5
	var pool_half_width: float = half - POOL_SIDE_EDGE
	var pool_near: float = half - POOL_BACK_EDGE - POOL_LENGTH
	var reserved: Array[Rect2] = [
		Rect2(-pool_half_width, pool_near, pool_half_width * 2.0, POOL_LENGTH + POOL_BACK_EDGE),
		Rect2(-29.0, -23.0, 10.0, 10.0),
		Rect2(15.0, -27.0, 10.0, 10.0),
		Rect2(11.0, 15.0, 10.0, 10.0),
		Rect2(-10.0, 10.0, 8.0, 8.0),
		Rect2(7.0, 3.0, 6.0, 6.0),
		# The walkway, kept clear from the spawn to the water's edge.
		Rect2(-9.0, -9.0, 18.0, 64.0),
	]

	# A gentle S rather than a straight line: the curve is what makes the path read
	# as laid out across the lawn instead of as a runway.
	var path := PackedVector3Array()
	for step: int in 5:
		path.append(_path_point(float(step) / 4.0))
	var slabs: int = Decor.stone_path(decor, path, rng)

	# Lanterns alternate sides of the walkway; benches sit on the west side facing
	# it. Both sample the same curve the path was laid along, so they follow it.
	var lanterns: int = 0
	for index: int in 4:
		var t: float = 0.13 + float(index) * 0.23
		var side: float = 1.0 if index % 2 == 0 else -1.0
		var lantern := Decor.lantern(rng)
		lantern.position = _path_point(t) + Vector3(side * 2.5, 0.0, 0.0)
		decor.add_child(lantern)
		lanterns += 1

	var benches: int = 0
	for index: int in 2:
		var bench := Decor.bench(rng)
		bench.position = _path_point(0.3 + float(index) * 0.36) + Vector3(-3.4, 0.0, 0.0)
		# Facing the walkway, which runs roughly north.
		bench.rotation_degrees = Vector3(0.0, 90.0, 0.0)
		decor.add_child(bench)
		benches += 1

	# Trees in four bands: the two side edges, a grove west of the walkway, and a
	# band across the approach to the pond that is deliberately allowed to overlap
	# the water so the reserved list is doing real work rather than guarding a zone
	# nothing could land in anyway.
	var trees: int = 0
	var tree_zones: Array[Rect2] = [
		Rect2(-half + 4.0, -half + 4.0, 26.0, 148.0),
		Rect2(half - 30.0, -half + 4.0, 26.0, 148.0),
		Rect2(-46.0, -8.0, 24.0, 42.0),
		Rect2(-half + 4.0, 40.0, 148.0, 38.0),
	]
	for zone: Rect2 in tree_zones:
		for _slot: int in 3:
			var spot: Vector2 = Decor.free_spot(zone, reserved, rng, 4.5)
			if spot == Vector2.INF:
				continue
			var tree := Decor.tree(rng)
			tree.position = Vector3(spot.x, 0.0, spot.y)
			decor.add_child(tree)
			trees += 1

	# Flowers on the strip of grass between the lawn's edge and the water.
	var flowers: int = 0
	var bank := Rect2(-pool_half_width, pool_near - 4.2, pool_half_width * 2.0, 3.8)
	for _slot: int in 6:
		var spot: Vector2 = Decor.free_spot(bank, reserved, rng, 1.0)
		if spot == Vector2.INF:
			continue
		var cluster := Decor.flower_cluster(rng)
		cluster.position = Vector3(spot.x, 0.0, spot.y)
		decor.add_child(cluster)
		flowers += 1

	return {
		"path_slabs": slabs,
		"lanterns": lanterns,
		"benches": benches,
		"trees": trees,
		"flowers": flowers,
	}


## A point on the walkway curve. Shared by the path, the lanterns and the benches
## so the three cannot disagree about where the path went.
func _path_point(t: float) -> Vector3:
	return Vector3(sin(t * PI) * 5.0, 0.0, -6.0 + t * 60.0)


## The lawn centre is a legal standing spot by construction — flat, outdoors,
## clear of the rooms.
func _find_spawn_position() -> Vector3:
	return Vector3(0.0, 1.2, 0.0)


func _material(color: Color, roughness: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	return material
