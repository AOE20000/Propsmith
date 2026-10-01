extends ModBase
## Example mod for the vehicle extension point.
##
## The `lighthouse` mod covers terrain, props, landmarks, items and combat. This one
## covers the piece that has no counterpart there — `add_vehicle_factory` — so
## "a mod can add a vehicle" is demonstrated rather than only documented, and the
## boot report grows a second entry that proves it was placed.
##
## It deliberately does not build its own chassis. `VehicleScene` is the project's own
## builder and it is public, so a mod that wants a *different* car tunes the result
## instead of re-deriving wheels, suspension, collider and seat. That is also what
## keeps the mod working when the default vehicle gains a feature: it inherits it.

const VEHICLE_ID: StringName = &"garage_buggy"


func _on_register() -> void:
	display_name = "车库：轻量越野车"
	version = "1.0.0"
	author = "example"

	context.add_vehicle_factory(VEHICLE_ID, _make_buggy)
	log_message("已注册载具：轻量越野车（更轻、马力更足、极速更高）")


## Called by `VehicleSystem` once the world exists. Returning a `Vehicle` (not a bare
## `VehicleBody3D`) is what lets the result be entered: the seat interaction and the
## rider pinning both live on `Vehicle`.
func _make_buggy() -> Vehicle:
	var vehicle: Vehicle = VehicleScene.build("Vehicle_garage_buggy")
	# Lighter and more powerful than the stock pickup, which makes it noticeably
	# twitchier — the trade a "buggy" implies.
	vehicle.mass = 720.0
	vehicle.max_engine_force = 2600.0
	vehicle.max_speed = 34.0
	vehicle.brake_force = 70.0
	vehicle.enter_verb = "坐进越野车"
	vehicle.exit_verb = "离开越野车"
	return vehicle
