extends Node3D
class_name VehicleSystem
## Owns the session's vehicles, registered as the `vehicle_system` service.
##
## Kept as a node under the world rather than as loose objects so a vehicle's
## lifetime is visibly tied to the map: tearing the world down takes the cars
## with it, and nothing has to remember to free them.
##
## Mod vehicles come through the same door as everything else. A mod registers a
## factory with `context.add_vehicle_factory`, and this system places one of each
## beside the default vehicle — so "the mod adds a vehicle" needs no hook in the
## world builder, the player, or the seat.
##
## Placement is *not* persisted (see `Vehicle`), but which vehicles exist is
## reported, so the headless smoke test can prove the fleet was built rather than
## merely declared.

var vehicles: Array[Vehicle] = []

## Parked this far from the anchor. A vehicle dropped inside the player's capsule
## launches the character on the next physics step, which is exactly the kind of bug
## the runtime smoke test's settled-position check exists to catch.
const PARK_MIN_RADIUS: float = 12.0
const PARK_MAX_RADIUS: float = 48.0
const RING_STEP: float = 6.0
const RING_SAMPLES: int = 12
const MAX_PARK_SLOPE_DEGREES: float = 9.0
## How far above the sampled ground a vehicle is placed, so it drops onto the
## terrain instead of starting inside it.
const SPAWN_CLEARANCE: float = 1.2


## Place one vehicle of each kind: the core's own, then one per registered mod
## factory. Returns the ids that were placed.
##
## Each vehicle is parked at its own anchor along +X so two never spawn inside each
## other.
func spawn_fleet(world: Node3D, query: SurfaceQuery, near: Vector3) -> PackedStringArray:
	var placed: PackedStringArray = PackedStringArray()
	var origin: Vector3 = _find_flat_ground(query, near, PARK_MIN_RADIUS, PARK_MAX_RADIUS)

	if spawn_vehicle(world, &"pickup", origin) != null:
		placed.append("pickup")

	var index: int = 1
	for entry: Dictionary in _mod_vehicle_entries():
		var vehicle_id: StringName = entry.get("id", &"")
		var anchor: Vector3 = origin + Vector3(4.6 * float(index), 0.0, 0.0)
		# The anchor is already clear of the player, so this one may park on the spot
		# itself rather than having to search outward.
		var spot: Vector3 = _find_flat_ground(query, anchor, 0.0, RING_STEP)
		if spawn_vehicle(world, vehicle_id, spot) != null:
			placed.append(String(vehicle_id))
			index += 1
	return placed


## Build and add one vehicle. `vehicle_id` of `pickup` builds the core vehicle;
## anything else must be provided by a mod, otherwise this reports and returns null.
func spawn_vehicle(world: Node3D, vehicle_id: StringName, position: Vector3) -> Vehicle:
	var vehicle: Vehicle = null
	if vehicle_id == &"pickup":
		vehicle = VehicleScene.build("Vehicle_pickup")
	else:
		vehicle = _build_from_mod(vehicle_id)
	if vehicle == null:
		return null

	# Added first, positioned second: a node outside the tree has no global
	# transform, and writing one raises an engine error about not being in the tree.
	world.add_child(vehicle)
	vehicle.global_position = position
	# Pointed at the world origin, so a vehicle parked away from the centre is
	# not left nose-out to nowhere.
	var look_target := Vector3(0.0, position.y, 0.0)
	if Vector3(position.x, 0.0, position.z).length_squared() > 1.0:
		vehicle.look_at_from_position(position, look_target, Vector3.UP)

	vehicles.append(vehicle)
	Events.vehicle_spawned.emit(vehicle, vehicle_id)
	return vehicle


func vehicle_count() -> int:
	return vehicles.size()


func occupied_count() -> int:
	var count: int = 0
	for vehicle: Vehicle in vehicles:
		if is_instance_valid(vehicle) and vehicle.is_occupied():
			count += 1
	return count


## Human-readable status for the boot report and the debug overlay.
func describe() -> Array[String]:
	var lines: Array[String] = []
	for vehicle: Vehicle in vehicles:
		if is_instance_valid(vehicle):
			lines.append(vehicle.describe())
	return lines


## Mod-registered vehicles, in the project's single deterministic order.
func _mod_vehicle_entries() -> Array[Dictionary]:
	return ModHost.content_ordered(&"vehicle")


## Instantiate a mod's vehicle. Only a `Vehicle` is accepted: a bare
## `VehicleBody3D` would drive but could not be entered, which is a worse failure
## than being refused here with a reason.
func _build_from_mod(vehicle_id: StringName) -> Vehicle:
	var entry: Dictionary = ModHost.content(&"vehicle").get(vehicle_id, {}) as Dictionary
	if entry.is_empty():
		push_warning("VehicleSystem: no provider registered for vehicle '%s'" % vehicle_id)
		return null
	var factory: Callable = entry.get("factory", Callable())
	if not factory.is_valid():
		push_warning("VehicleSystem: vehicle '%s' has no valid factory" % vehicle_id)
		return null
	var produced: Variant = factory.call()
	if not (produced is Vehicle):
		push_warning("VehicleSystem: vehicle '%s' must produce a Vehicle (got %s)" % [
			vehicle_id, type_string(typeof(produced)),
		])
		return null
	var vehicle: Vehicle = produced
	vehicle.name = "Vehicle_%s" % vehicle_id
	return vehicle


## Look for ground flat enough to park on, sampling rings outward from `anchor`
## between `min_radius` and `max_radius`. Reusing the surface query's own placement
## test keeps "is this drivable" the same question the spawn search already asks.
##
## `min_radius` of 0 also offers the anchor itself; a positive one does not, which is
## what keeps the fleet out of the player's capsule.
func _find_flat_ground(
	query: SurfaceQuery, anchor: Vector3, min_radius: float, max_radius: float
) -> Vector3:
	if query == null or not query.is_ready():
		return anchor + Vector3(maxf(min_radius, RING_STEP), SPAWN_CLEARANCE, 0.0)

	var candidates: Array[Vector3] = []
	if min_radius <= 0.0:
		candidates.append(anchor)
	var radius: float = maxf(min_radius, RING_STEP)
	while radius <= max_radius:
		for step: int in RING_SAMPLES:
			var angle: float = TAU * float(step) / float(RING_SAMPLES)
			candidates.append(anchor + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius))
		radius += RING_STEP

	for candidate: Vector3 in candidates:
		if not query.is_placeable(candidate.x, candidate.z, MAX_PARK_SLOPE_DEGREES):
			continue
		return Vector3(
			candidate.x, query.height_at(candidate.x, candidate.z) + SPAWN_CLEARANCE, candidate.z
		)

	# Placing the fleet somewhere controlled beats not placing it: a terrain with no
	# flat spot in range still gets a vehicle, offset so it is not inside the player.
	var fallback := anchor + Vector3(maxf(min_radius, RING_STEP), 0.0, 0.0)
	return Vector3(
		fallback.x, query.height_at(fallback.x, fallback.z) + SPAWN_CLEARANCE, fallback.z
	)
