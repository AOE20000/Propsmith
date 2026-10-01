extends RefCounted
class_name VehicleScene
## Assembles the default vehicle in code, mirroring `PlayerScene`: the structure is
## reviewable as a diff, cannot drift from the scripts, and is verified by the
## headless smoke test. Replacing it with a designed model later means keeping the
## node names, not rewriting `Vehicle`.
##
## Shape:
##   Vehicle (VehicleBody3D)
##   ├── Body (CollisionShape3D)
##   ├── Visual (Node3D)
##   │   ├── Hull / Cabin / Windshield / Lights (MeshInstance3D)
##   ├── WheelFL / WheelFR (VehicleWheel3D, steer) > MeshInstance3D
##   ├── WheelRL / WheelRR (VehicleWheel3D, traction) > MeshInstance3D
##   ├── Seat (VehicleSeat)          <- what the player's probe finds
##   └── ExitPoint (Marker3D)
##
## Everything is primitives: the island has no vehicle art, and a box car that reads
## clearly is more useful than a placeholder mesh that does not.

## Tuned for a ~1.1 t chassis. The prototype's 1000 N engine force was for a far
## lighter body; these values are a starting point, not a handling model.
const MASS: float = 1100.0
const CHASSIS_SIZE := Vector3(1.9, 0.75, 4.1)
const CHASSIS_CENTRE_Y: float = 0.62
const WHEEL_RADIUS: float = 0.42
const WHEEL_WIDTH: float = 0.3
const WHEEL_BASE_Z: float = 1.35
const TRACK_X: float = 0.92
const WHEEL_Y: float = 0.45
## How far up the driver's eye line sits inside the cabin.
const SEAT_Y: float = 0.95
## Where the driver is put down on exit: beside the hull, not inside it.
const EXIT_OFFSET := Vector3(-1.9, 0.55, 0.0)


## Build one vehicle. `vehicle_id` only names the node, so a diagnostic can tell two
## vehicles apart.
static func build(vehicle_id: String = "vehicle") -> Vehicle:
	var vehicle := Vehicle.new()
	vehicle.name = vehicle_id if not vehicle_id.is_empty() else "Vehicle"
	vehicle.mass = MASS
	# Keeps the hull from pivoting on a single contact point when it lands badly.
	vehicle.center_of_mass_mode = VehicleBody3D.CENTER_OF_MASS_MODE_CUSTOM
	vehicle.center_of_mass = Vector3(0.0, CHASSIS_CENTRE_Y, 0.0)

	vehicle.add_child(_build_collider())
	vehicle.add_child(_build_visual())

	for offset: Vector3 in [
		Vector3(-TRACK_X, WHEEL_Y, -WHEEL_BASE_Z),
		Vector3(TRACK_X, WHEEL_Y, -WHEEL_BASE_Z),
		Vector3(-TRACK_X, WHEEL_Y, WHEEL_BASE_Z),
		Vector3(TRACK_X, WHEEL_Y, WHEEL_BASE_Z),
	]:
		vehicle.add_child(_build_wheel(offset))

	vehicle.add_child(_build_seat())
	vehicle.add_child(_build_exit_point())
	return vehicle


static func _build_collider() -> CollisionShape3D:
	var collider := CollisionShape3D.new()
	collider.name = "Body"
	var box := BoxShape3D.new()
	box.size = CHASSIS_SIZE
	collider.shape = box
	collider.position = Vector3(0.0, CHASSIS_CENTRE_Y, 0.0)
	return collider


static func _build_visual() -> Node3D:
	var visual := Node3D.new()
	visual.name = "Visual"

	var hull_material := StandardMaterial3D.new()
	hull_material.albedo_color = Color(0.30, 0.36, 0.30)
	hull_material.roughness = 0.5
	hull_material.metallic = 0.25

	var hull := MeshInstance3D.new()
	hull.name = "Hull"
	var hull_mesh := BoxMesh.new()
	hull_mesh.size = CHASSIS_SIZE
	hull.mesh = hull_mesh
	hull.material_override = hull_material
	hull.position = Vector3(0.0, CHASSIS_CENTRE_Y, 0.0)
	visual.add_child(hull)

	# A flat bed with a raised cab: the silhouette the original pickup had, without
	# needing its `.glb`.
	var cab := MeshInstance3D.new()
	cab.name = "Cabin"
	var cab_mesh := BoxMesh.new()
	cab_mesh.size = Vector3(1.78, 0.62, 1.75)
	cab.mesh = cab_mesh
	cab.material_override = hull_material
	cab.position = Vector3(0.0, CHASSIS_CENTRE_Y + 0.68, 0.42)
	visual.add_child(cab)

	var glass_material := StandardMaterial3D.new()
	glass_material.albedo_color = Color(0.34, 0.45, 0.55, 0.55)
	glass_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass_material.roughness = 0.08

	var windshield := MeshInstance3D.new()
	windshield.name = "Windshield"
	var windshield_mesh := BoxMesh.new()
	windshield_mesh.size = Vector3(1.6, 0.5, 0.09)
	windshield.mesh = windshield_mesh
	windshield.material_override = glass_material
	windshield.position = Vector3(0.0, CHASSIS_CENTRE_Y + 0.7, -0.48)
	visual.add_child(windshield)

	var lamp_material := StandardMaterial3D.new()
	lamp_material.albedo_color = Color(1.0, 0.96, 0.82)
	lamp_material.emission_enabled = true
	lamp_material.emission = Color(1.0, 0.95, 0.78)
	lamp_material.emission_energy_multiplier = 2.5

	for side: float in [-0.62, 0.62]:
		var lamp := MeshInstance3D.new()
		lamp.name = "Headlamp%s" % ("L" if side < 0.0 else "R")
		var lamp_mesh := BoxMesh.new()
		lamp_mesh.size = Vector3(0.34, 0.18, 0.08)
		lamp.mesh = lamp_mesh
		lamp.material_override = lamp_material
		lamp.position = Vector3(side, CHASSIS_CENTRE_Y + 0.12, -CHASSIS_SIZE.z * 0.5 - 0.02)
		visual.add_child(lamp)

	return visual


## One wheel. The two front wheels steer and the two rear wheels drive, which is the
## conventional split and the easiest to reason about when the car misbehaves.
static func _build_wheel(offset: Vector3) -> VehicleWheel3D:
	var front: bool = offset.z < 0.0
	var wheel := VehicleWheel3D.new()
	wheel.name = "Wheel%s%s" % ["F" if front else "R", "L" if offset.x < 0.0 else "R"]
	wheel.position = offset
	wheel.use_as_steering = front
	wheel.use_as_traction = not front

	wheel.wheel_radius = WHEEL_RADIUS
	wheel.wheel_rest_length = 0.15
	wheel.wheel_friction_slip = 4.0
	# Stiffer than the engine defaults: the defaults are sized for a much lighter
	# chassis and let a tonne settle through its own suspension.
	wheel.suspension_travel = 0.25
	wheel.suspension_stiffness = 45.0
	wheel.suspension_max_force = 9000.0
	wheel.damping_compression = 0.8
	wheel.damping_relaxation = 0.9

	var tyre_material := StandardMaterial3D.new()
	tyre_material.albedo_color = Color(0.08, 0.08, 0.09)
	tyre_material.roughness = 0.95

	var tyre := MeshInstance3D.new()
	tyre.name = "Tyre"
	var tyre_mesh := CylinderMesh.new()
	tyre_mesh.top_radius = WHEEL_RADIUS
	tyre_mesh.bottom_radius = WHEEL_RADIUS
	tyre_mesh.height = WHEEL_WIDTH
	tyre_mesh.radial_segments = 14
	tyre.mesh = tyre_mesh
	tyre.material_override = tyre_material
	# A cylinder's axis is Y, a wheel's is X, so the mesh is stood on its side.
	tyre.rotation_degrees = Vector3(0.0, 0.0, 90.0)
	wheel.add_child(tyre)
	return wheel


## The seat marker is also the interactable, and sits where the driver's body goes.
## That placement is deliberate: it means the same node serves as the pin target
## while driving and as the thing the probe finds while standing outside.
static func _build_seat() -> VehicleSeat:
	var seat := VehicleSeat.new()
	seat.name = "Seat"
	seat.position = Vector3(-0.45, SEAT_Y, 0.0)
	seat.verb = "上车"
	return seat


static func _build_exit_point() -> Node3D:
	var marker := Marker3D.new()
	marker.name = "ExitPoint"
	marker.position = EXIT_OFFSET
	return marker
