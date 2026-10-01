extends Node
class_name TerrainGenerator
## Builds the island heightfield and hands it to Terrain3D, then publishes a CPU
## copy to the `terrain_query` service.
##
## Layered composition, in order:
##   1. radial island mask     — where land exists at all
##   2. continent noise        — the large landmass shape
##   3. hill noise             — walkable relief
##   4. ridged mountain noise  — sparse high ground
##   5. height curve           — flattens valleys, keeps peaks
##   6. mod terrain modifiers  — deterministic, ordered by (order, id)
##
## Generation is deterministic in the seed alone, which is what lets a save file
## store a single integer instead of a whole world.

## `region_size` takes the pixel size itself, not an enum index: its hint string is
## "64:64,128:128,256:256,...", so passing an index makes Terrain3D reject it with
## "Invalid region size". A typed `Array` is used because `PackedInt32Array` is not
## a constant expression in GDScript.
const VALID_REGION_SIZES: Array[int] = [64, 128, 256, 512, 1024, 2048]

signal generation_progress(step: String, ratio: float)

var config: TerrainConfig = TerrainConfig.new()

var _continent_noise: FastNoiseLite = FastNoiseLite.new()
var _hill_noise: FastNoiseLite = FastNoiseLite.new()
var _mountain_noise: FastNoiseLite = FastNoiseLite.new()

var _terrain: Node = null
var _heightfield: PackedFloat32Array = PackedFloat32Array()
var _resolution: int = 0
var _extent: float = 0.0

## Mod-supplied reshapers, resolved **once per world build** by `WorldBuilder`.
##
## These used to be looked up inside the sampler, which meant `ModHost.content()` ran
## for every height sample: the CPU field alone is ~484² samples and the Terrain3D
## region fill is ~3.2 M more, so one world build performed millions of cross-mod
## dictionary merges, each followed by an allocation and a sort. Holding them here is
## what makes the sampler a pure function of its arguments.
var _modifiers: Array[Dictionary] = []


func _init() -> void:
	_configure_noise()


func _configure_noise() -> void:
	_continent_noise.seed = config.seed
	_continent_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_continent_noise.frequency = 0.0016
	_continent_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_continent_noise.fractal_octaves = 4
	_continent_noise.fractal_lacunarity = 2.0
	_continent_noise.fractal_gain = 0.5

	_hill_noise.seed = config.seed + 1013
	_hill_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_hill_noise.frequency = 0.012
	_hill_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_hill_noise.fractal_octaves = 3
	_hill_noise.fractal_gain = 0.45

	_mountain_noise.seed = config.seed + 7717
	_mountain_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_mountain_noise.frequency = 0.0045
	_mountain_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	_mountain_noise.fractal_octaves = 5
	_mountain_noise.fractal_gain = 0.5


## Raw composed height, before Terrain3D sees it. Public so tests and mods can
## reason about the same field the generator uses.
func height_at(world_x: float, world_z: float) -> float:
	var mask: float = _island_mask(world_x, world_z)
	if mask <= 0.0:
		return _sea_floor()
	var continent: float = _continent_noise.get_noise_2d(world_x, world_z) * 0.5 + 0.5
	var hills: float = _hill_noise.get_noise_2d(world_x, world_z) * 0.5 + 0.5
	var ridge: float = absf(_mountain_noise.get_noise_2d(world_x, world_z))
	ridge = pow(1.0 - ridge, 2.0)

	var relief: float = continent * config.continent_weight
	relief += hills * config.hill_weight
	relief += ridge * config.mountain_weight * continent

	# Bias toward the lower end so most of the island stays walkable.
	relief = pow(clampf(relief, 0.0, 1.0), config.height_curve)

	var height: float = relief * config.max_height * mask
	height = _apply_modifiers(world_x, world_z, height, mask)
	return maxf(height, _sea_floor())


func _sea_floor() -> float:
	return -6.0


## Snap a requested region size onto one Terrain3D accepts, so a bad config value
## degrades to the nearest valid size instead of failing generation.
func _nearest_region_size(requested: int) -> int:
	var best: int = VALID_REGION_SIZES[0]
	var best_distance: int = absi(requested - best)
	for candidate: int in VALID_REGION_SIZES:
		var distance: int = absi(requested - candidate)
		if distance < best_distance:
			best = candidate
			best_distance = distance
	return best


func _island_mask(world_x: float, world_z: float) -> float:
	var distance: float = sqrt(world_x * world_x + world_z * world_z)
	if distance >= config.island_radius:
		return 0.0
	var normalised: float = distance / config.island_radius
	return pow(1.0 - normalised * normalised, config.island_falloff)


## Publish the reshapers to apply. Must be called before generation: modifiers
## registered later could never affect terrain that already exists, so the ordering
## here matches the old behaviour exactly rather than changing it.
func set_modifiers(entries: Array[Dictionary]) -> void:
	_modifiers = entries


## Mod-supplied reshapers, applied in the order `ModHost.content_ordered()` decided so
## two runs of the same seed with the same mods produce identical terrain.
func _apply_modifiers(world_x: float, world_z: float, height: float, falloff: float) -> float:
	if _modifiers.is_empty():
		return height
	var result: float = height
	for entry: Dictionary in _modifiers:
		var modifier: Callable = entry.get("modifier", Callable())
		if modifier.is_valid():
			result = float(modifier.call(world_x, world_z, result, falloff))
	return result


## Build the CPU heightfield only. Split from mesh generation so the field can be
## tested, and so modifiers can inspect it, without an engine terrain.
func build_heightfield() -> PackedFloat32Array:
	var step: float = config.sample_step
	var extent: float = config.island_radius * 1.15
	var resolution: int = int(ceil(extent * 2.0 / step)) + 1
	var values: PackedFloat32Array = PackedFloat32Array()
	values.resize(resolution * resolution)
	for z_index: int in resolution:
		var world_z: float = -extent + float(z_index) * step
		var row: int = z_index * resolution
		for x_index: int in resolution:
			var world_x: float = -extent + float(x_index) * step
			values[row + x_index] = height_at(world_x, world_z)
	_heightfield = values
	_resolution = resolution
	_extent = extent
	return values


## Create and fill the Terrain3D node under `parent`.
##
## Terrain3D is a GDExtension class, so it is constructed through `ClassDB` by
## name rather than referenced as a global type. That keeps this file loadable —
## and the project validatable — even when the addon is not installed, and it is
## why the terrain backend can be swapped for a plain mesh later.
func generate(parent: Node3D) -> Node:
	if not ClassDB.class_exists("Terrain3D"):
		push_error("TerrainGenerator: Terrain3D is unavailable; install addons/terrain_3d")
		return null

	var terrain: Object = ClassDB.instantiate("Terrain3D")
	if terrain == null or not (terrain is Node):
		push_error("TerrainGenerator: Terrain3D could not be instantiated")
		return null

	var terrain_node: Node = terrain
	terrain_node.name = "Terrain3D"
	parent.add_child(terrain_node)

	# Set after parenting: Terrain3D pushes region settings into its Data resource
	# during `_ready`, and the property takes a pixel size, not an enum index.
	terrain_node.set("vertex_spacing", config.vertex_spacing)
	terrain_node.set("region_size", _nearest_region_size(config.region_size))

	generation_progress.emit("配置地形", 0.05)

	var assets: Object = _build_assets()
	if assets != null:
		terrain_node.call("set_assets", assets)

	generation_progress.emit("生成高度图", 0.15)
	_fill_regions(terrain_node)

	generation_progress.emit("生成地表网格", 0.7)
	_apply_texture_strata(terrain_node)

	var data: Object = terrain_node.call("get_data")
	if data != null:
		data.call("update_maps", 0, true, true)
		data.call("calc_height_range", true)

	_terrain = terrain_node
	generation_progress.emit("地形就绪", 1.0)
	return terrain_node


func _build_assets() -> Object:
	if not ClassDB.class_exists("Terrain3DAssets"):
		return null
	var assets: Object = ClassDB.instantiate("Terrain3DAssets")
	if assets == null:
		return null

	var textures: Array[String] = [
		"res://assets/terrain/textures/ground037_alb_ht.png",
		"res://assets/terrain/textures/rock023_alb_ht.png",
	]
	for index: int in textures.size():
		if not ResourceLoader.exists(textures[index]):
			continue
		var texture: Resource = load(textures[index])
		if texture != null:
			assets.call("set_texture", index, texture)
	if assets.has_method("update_texture_list"):
		assets.call("update_texture_list")
	return assets


## Fill every region of the island. Heights are computed once per pixel and
## stored, so texture stratification does not have to recompute noise.
func _fill_regions(terrain: Node) -> void:
	var data: Object = terrain.call("get_data")
	if data == null:
		return
	var regions_per_axis: int = config.regions_per_axis()
	var half: int = int(floor(float(regions_per_axis) / 2.0))
	var region_size: int = config.region_size
	var total: int = regions_per_axis * regions_per_axis
	var done: int = 0

	for region_z: int in range(-half, half + 1):
		for region_x: int in range(-half, half + 1):
			var location := Vector2i(region_x, region_z)
			data.call("add_region_blank", location, false)
			var region_origin_x: int = region_x * region_size
			var region_origin_z: int = region_z * region_size
			for pixel_z: int in region_size:
				var world_z: float = float(region_origin_z + pixel_z) * config.vertex_spacing
				for pixel_x: int in region_size:
					var world_x: float = float(region_origin_x + pixel_x) * config.vertex_spacing
					data.call("set_height", Vector3(world_x, 0.0, world_z), height_at(world_x, world_z))
			done += 1
			if done % 4 == 0 or done == total:
				generation_progress.emit("生成高度图", 0.15 + 0.5 * float(done) / float(maxi(total, 1)))


## A texture per height band, so the island reads at a glance without hand
## painting: sand at the waterline, grass inland, rock on slopes and peaks.
func _apply_texture_strata(terrain: Node) -> void:
	var data: Object = terrain.call("get_data")
	if data == null:
		return
	var region_size: int = config.region_size
	var regions_per_axis: int = config.regions_per_axis()
	var half: int = int(floor(float(regions_per_axis) / 2.0))
	var texture_count: int = 1
	var assets: Object = terrain.call("get_assets")
	if assets != null and assets.has_method("get_texture_count"):
		texture_count = int(assets.call("get_texture_count"))

	var max_height: float = maxf(config.max_height, 1.0)
	for region_z: int in range(-half, half + 1):
		for region_x: int in range(-half, half + 1):
			var region_origin_x: int = region_x * region_size
			var region_origin_z: int = region_z * region_size
			for pixel_z: int in region_size:
				var world_z: float = float(region_origin_z + pixel_z) * config.vertex_spacing
				for pixel_x: int in region_size:
					var world_x: float = float(region_origin_x + pixel_x) * config.vertex_spacing
					var height: float = float(data.call("get_height", Vector3(world_x, 0.0, world_z)))
					var normal: Vector3 = data.call("get_normal", Vector3(world_x, 0.0, world_z)) as Vector3
					var slope: float = rad_to_deg(acos(clampf(normal.dot(Vector3.UP), -1.0, 1.0)))
					var texture_id: int = _texture_for(height / max_height, slope, texture_count)
					data.call("set_control_base_id", Vector3(world_x, 0.0, world_z), texture_id)


func _texture_for(height_ratio: float, slope_degrees: float, texture_count: int) -> int:
	if texture_count <= 1:
		return 0
	if height_ratio < 0.06:
		return 0
	if slope_degrees > 34.0 or height_ratio > 0.72:
		return 1
	return 0


## CPU heightfield for the `terrain_query` service.
func heightfield() -> PackedFloat32Array:
	return _heightfield


func resolution() -> int:
	return _resolution


func extent() -> float:
	return _extent
