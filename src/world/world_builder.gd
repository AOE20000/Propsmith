extends Node
class_name WorldBuilder
## Orchestrates world construction, registered as the `world_builder` service.
##
## The builder owns ordering and nothing else: each stage is a separate module
## (terrain, environment, scatter, points of interest), so replacing one stage
## never means editing the others. Every stage reports through
## `Events.world_generation_progress`, which is what the loading screen draws.
##
## Stage order is a contract mods rely on:
##   terrain -> query published -> environment -> mod generate hook ->
##   scatter -> points of interest -> mod populate hook

var config: TerrainConfig = TerrainConfig.new()

var terrain_generator: TerrainGenerator = null
var terrain_node: Node = null

var _scatter: WorldScatter = null
var _poi_placer: PoiPlacer = null
var _environment: WorldEnvironment3D = null


func _init() -> void:
	terrain_generator = TerrainGenerator.new()
	_scatter = WorldScatter.new()
	_poi_placer = PoiPlacer.new()
	_environment = WorldEnvironment3D.new()


## Build the whole world under `world_root`. Returns false when a required stage
## failed, so the caller can abort boot instead of dropping the player into a
## half-built island.
func build(world_root: Node3D, seed_value: int) -> bool:
	config.seed = seed_value
	terrain_generator.config = config

	Events.world_generation_started.emit(seed_value)
	var progress := func(step: String, ratio: float) -> void:
		Events.world_generation_progress.emit(step, ratio)
	terrain_generator.generation_progress.connect(progress)

	progress.call("生成地形", 0.02)
	terrain_node = terrain_generator.generate(world_root)
	if terrain_node == null:
		Events.notify("地形后端不可用：请确认 addons/terrain_3d 已安装", Events.NotifyLevel.WARNING)
		return false

	progress.call("构建地形查询", 0.72)
	var query: TerrainQuery = Services.get_as(&"terrain_query", &"TerrainQuery") as TerrainQuery
	if query == null:
		push_error("WorldBuilder: terrain_query service is missing")
		return false
	config.to_terrain_query(query)
	var field: PackedFloat32Array = terrain_generator.build_heightfield()
	query.set_heightfield(field, terrain_generator.resolution(), config.sample_step, terrain_generator.extent())
	query.has_engine_terrain = true

	progress.call("构建天空与水面", 0.76)
	_environment.build(world_root, config)

	progress.call("通知 Mod 介入地形", 0.8)
	ModHost.notify_world_generate(world_root)

	progress.call("散布植被与岩石", 0.84)
	_scatter.scatter(world_root, query, config)

	progress.call("放置地标", 0.94)
	_poi_placer.place(world_root, query, config)

	progress.call("通知 Mod 补充内容", 0.98)
	ModHost.notify_world_populate(world_root)

	progress.call("完成", 1.0)
	return true


## Find a good spawn: on land, flat enough, above water, near the island centre
## so the player starts inland rather than on a cliff edge.
func find_spawn_position(query: TerrainQuery) -> Vector3:
	var attempts: int = 240
	var rng := RandomNumberGenerator.new()
	rng.seed = config.seed
	for attempt: int in attempts:
		var radius: float = config.spawn_search_radius * sqrt(rng.randf())
		var angle: float = rng.randf() * TAU
		var x: float = cos(angle) * radius
		var z: float = sin(angle) * radius
		if not query.is_placeable(x, z, 12.0):
			continue
		if query.height_at(x, z) < 3.0:
			continue
		var position: Vector3 = Vector3(x, query.height_at(x, z) + 1.0, z)
		return position
	# Fall back to the geometric centre so boot never fails for want of a slope.
	return Vector3(0.0, query.height_at(0.0, 0.0) + 2.0, 0.0)


func teardown(world_root: Node3D) -> void:
	Events.world_teardown_started.emit()
	if is_instance_valid(world_root):
		world_root.queue_free()
	if terrain_node != null and is_instance_valid(terrain_node):
		terrain_node.queue_free()
	terrain_node = null
	var query: TerrainQuery = Services.get_as(&"terrain_query", &"TerrainQuery") as TerrainQuery
	if query != null:
		query.clear()
