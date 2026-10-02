extends Node
class_name SurfaceQuery
## The only sanctioned way to ask "what is the ground doing here?", registered as
## the `surface_query` service.
##
## The island version of this service sampled a CPU heightfield, because the height
## field existed as data. A PLATEAU city has no heightfield — its ground is the
## collision geometry the map source builds — so this implementation answers from
## the physics space instead: one downward ray per query.
##
## The ray only collides with the map's dedicated physics layer (`GROUND_MASK`),
## which the map source stamps onto every static body it creates. Players, vehicles
## and agents live on the default layer, so a query can never hit something that
## walks, drives, or is about to — no exclusion lists to forget.

## Bit 2 of the collision layers. The map source stamps `layer = 1 | GROUND_MASK`
## on every static body it builds, so the default `mask = 1` world keeps working
## while this query alone can address the map geometry.
const GROUND_MASK: int = 1 << 1
## Rays start above every plausible building (Tokyo's tallest is ~330 m) and end
## below the ground plane, so a missed hit always means "open ground", never
## "started inside geometry".
const RAY_ORIGIN_Y: float = 900.0
const RAY_BOTTOM_Y: float = -100.0
## Returned by `height_at` when the ray hits nothing: the ground plane itself.
const OPEN_GROUND_Y: float = 0.0

var _ready_flag: bool = false


## Called by the map source once its static geometry exists in the physics space.
## Before that a query would answer from an empty world, which reads as valid
## "ground at y = 0" — exactly the failure a half-built map must not look like.
func mark_ready() -> void:
	_ready_flag = true


func clear() -> void:
	_ready_flag = false


func is_ready() -> bool:
	return _ready_flag


## Ground height under (x, z). Open ground (no hit) reports `OPEN_GROUND_Y`,
## which is where the map source puts its ground plane.
func height_at(world_x: float, world_z: float) -> float:
	if not _ready_flag:
		return OPEN_GROUND_Y
	var hit: Dictionary = _cast_ray(world_x, world_z)
	if hit.is_empty():
		return OPEN_GROUND_Y
	return (hit["position"] as Vector3).y


func height_of(world_position: Vector3) -> float:
	return height_at(world_position.x, world_position.z)


## A world position dropped onto the surface at the given clearance.
func sample_height(world_position: Vector3, clearance: float = 0.0) -> Vector3:
	var result: Vector3 = world_position
	result.y = height_at(world_position.x, world_position.z) + clearance
	return result


## Incline in degrees from the hit normal; 0 is flat, 90 is a wall.
## Open ground is flat by construction.
func slope_degrees_at(world_x: float, world_z: float) -> float:
	if not _ready_flag:
		return 0.0
	var hit: Dictionary = _cast_ray(world_x, world_z)
	if hit.is_empty():
		return 0.0
	return rad_to_deg(acos(clampf((hit["normal"] as Vector3).dot(Vector3.UP), -1.0, 1.0)))


## Whether a point can carry something: the surface exists, and is flat enough.
## In a city the ground plane answers everywhere outdoors, so this is really
## "not standing on a steep roof or a slope".
func is_placeable(world_x: float, world_z: float, max_slope_degrees: float = 35.0) -> bool:
	if not _ready_flag:
		return false
	return slope_degrees_at(world_x, world_z) <= max_slope_degrees


## What kind of surface is under (x, z): `&"ground"` (the city ground plane),
## `&"building"` (a footprint or roof), or `&"none"` (nothing — before the map
## exists). Distinguished by the `map_buildings` group the map source stamps, not
## by names, so the SDK's own node naming can never break it.
func surface_kind(world_x: float, world_z: float) -> StringName:
	if not _ready_flag:
		return &"none"
	var hit: Dictionary = _cast_ray(world_x, world_z)
	if hit.is_empty():
		return &"ground"
	var collider: Object = hit.get("collider")
	if collider is Node and (collider as Node).is_in_group(&"map_buildings"):
		return &"building"
	return &"ground"


func _cast_ray(world_x: float, world_z: float) -> Dictionary:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return {}
	var space: PhysicsDirectSpaceState3D = tree.root.world_3d.direct_space_state
	var params := PhysicsRayQueryParameters3D.create(
		Vector3(world_x, RAY_ORIGIN_Y, world_z),
		Vector3(world_x, RAY_BOTTOM_Y, world_z),
		GROUND_MASK,
	)
	params.collide_with_bodies = true
	params.collide_with_areas = false
	return space.intersect_ray(params)
