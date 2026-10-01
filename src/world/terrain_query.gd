extends Node
class_name TerrainQuery
## The only sanctioned way to ask "what is the ground doing here?", registered as
## the `terrain_query` service.
##
## Every consumer (player spawn, prop scatter, POI placement, mods) goes through
## this interface instead of touching Terrain3D, which is what keeps the terrain
## backend replaceable: swap the generating module and callers keep working.
##
## Sampling is served from a CPU heightfield built during generation. That is
## deliberate — Terrain3D's own `get_height()` is a per-call engine query, and
## prop scattering issues tens of thousands of them.

## Grid spacing in metres of the CPU heightfield used for queries.
const SAMPLE_STEP: float = 2.0
## Metres of half-extent sampled around the world origin.
const SAMPLE_EXTENT: float = 512.0
## Below this the surface is treated as water, not walkable ground.
const WATER_LEVEL: float = 0.0

var centre: Vector3 = Vector3.ZERO
var island_radius: float = 420.0
## Exponent of the radial mask: higher keeps more flat interior, then drops fast.
var island_falloff_curve: float = 1.35
var max_height: float = 48.0

var _heightfield: PackedFloat32Array = PackedFloat32Array()
var _resolution: int = 0
var _step: float = SAMPLE_STEP
var _extent: float = SAMPLE_EXTENT
var _ready_flag: bool = false
## Set when the Terrain3D node exists, so `height_at` can prefer engine truth.
var has_engine_terrain: bool = false


## Publish a generated heightfield. Called by the terrain generator once the
## surface is final, before anything is placed on it.
func set_heightfield(values: PackedFloat32Array, resolution: int, step: float, extent: float) -> void:
	_heightfield = values
	_resolution = resolution
	_step = step
	_extent = extent
	_ready_flag = resolution > 1 and values.size() == resolution * resolution


func is_ready() -> bool:
	return _ready_flag


func clear() -> void:
	_heightfield = PackedFloat32Array()
	_resolution = 0
	_ready_flag = false
	has_engine_terrain = false


## Bilinear-sampled ground height in world space. Outside the sampled extent the
## field clamps to its border, which reads as "flat ground continues".
func height_at(world_x: float, world_z: float) -> float:
	if not _ready_flag:
		return centre.y
	var grid_x: float = (world_x - centre.x + _extent) / _step
	var grid_z: float = (world_z - centre.z + _extent) / _step
	grid_x = clampf(grid_x, 0.0, float(_resolution - 1))
	grid_z = clampf(grid_z, 0.0, float(_resolution - 1))

	var x0: int = int(floor(grid_x))
	var z0: int = int(floor(grid_z))
	var x1: int = mini(x0 + 1, _resolution - 1)
	var z1: int = mini(z0 + 1, _resolution - 1)
	var tx: float = grid_x - float(x0)
	var tz: float = grid_z - float(z0)

	var h00: float = _heightfield[z0 * _resolution + x0]
	var h10: float = _heightfield[z0 * _resolution + x1]
	var h01: float = _heightfield[z1 * _resolution + x0]
	var h11: float = _heightfield[z1 * _resolution + x1]
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)


func height_of(world_position: Vector3) -> float:
	return height_at(world_position.x, world_position.z)


## A world position dropped onto the surface at the given clearance.
func sample_height(world_position: Vector3, clearance: float = 0.0) -> Vector3:
	var result: Vector3 = world_position
	result.y = height_at(world_position.x, world_position.z) + clearance
	return result


## Surface normal approximated from height differences.
func normal_at(world_x: float, world_z: float, delta: float = 1.0) -> Vector3:
	var left: float = height_at(world_x - delta, world_z)
	var right: float = height_at(world_x + delta, world_z)
	var back: float = height_at(world_x, world_z - delta)
	var front: float = height_at(world_x, world_z + delta)
	return Vector3(left - right, 2.0 * delta, back - front).normalized()


## Incline in degrees; 0 is flat, 90 is a cliff.
func slope_degrees_at(world_x: float, world_z: float, delta: float = 1.0) -> float:
	var normal: Vector3 = normal_at(world_x, world_z, delta)
	return rad_to_deg(acos(clampf(normal.dot(Vector3.UP), -1.0, 1.0)))


func is_underwater(world_x: float, world_z: float) -> bool:
	return height_at(world_x, world_z) < WATER_LEVEL


## Whether a point is on the island proper, using the same falloff the generator
## applies, so placement and generation agree about where land ends.
func is_on_land(world_x: float, world_z: float) -> bool:
	return island_falloff(world_x, world_z) > 0.05 and not is_underwater(world_x, world_z)


## Whether a point can carry a prop: on land, flat enough, and above water.
func is_placeable(world_x: float, world_z: float, max_slope_degrees: float = 35.0) -> bool:
	if not is_on_land(world_x, world_z):
		return false
	return slope_degrees_at(world_x, world_z) <= max_slope_degrees


## The generator's radial mask: 1 at the centre, 0 at the coast and beyond.
## Exposed so scatter code can bias density toward the interior.
func island_falloff(world_x: float, world_z: float) -> float:
	if island_radius <= 0.0:
		return 0.0
	var distance: float = Vector2(world_x - centre.x, world_z - centre.z).length()
	if distance >= island_radius:
		return 0.0
	var normalised: float = distance / island_radius
	return pow(1.0 - normalised * normalised, island_falloff_curve)


## Height range actually present in the field, for camera and fog tuning.
func height_range() -> Vector2:
	if not _ready_flag:
		return Vector2.ZERO
	var lowest: float = INF
	var highest: float = -INF
	for value: float in _heightfield:
		lowest = minf(lowest, value)
		highest = maxf(highest, value)
	return Vector2(lowest, highest)
