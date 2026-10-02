extends RefCounted
class_name PropFactory
## Code-built props for the sandbox. Every prop is a fully configured
## `RigidBody3D` — visual mesh, collision shape, mass, optional physics material —
## assembled from primitives, the same way every other scene in this project is
## built. A prop definition's factory returns one of these.

const DEFAULT_MASS: float = 10.0


## A box prop of the given size, colour and mass. The workhorse behind most of
## the built-in catalogue.
static func build_box(size: Vector3, color: Color, mass: float, roughness: float = 0.85) -> RigidBody3D:
	var body := _body(mass)
	var visual := MeshInstance3D.new()
	visual.name = "Visual"
	var box := BoxMesh.new()
	box.size = size
	visual.mesh = box
	visual.material_override = _material(color, roughness)
	body.add_child(visual)
	_attach_box_shape(body, size)
	return body


## A cylinder prop (barrels, drums, rollers).
static func build_cylinder(radius: float, height: float, color: Color, mass: float) -> RigidBody3D:
	var body := _body(mass)
	var visual := MeshInstance3D.new()
	visual.name = "Visual"
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = radius
	cylinder.bottom_radius = radius
	cylinder.height = height
	visual.mesh = cylinder
	visual.material_override = _material(color, 0.7)
	body.add_child(visual)
	var shape := CollisionShape3D.new()
	shape.name = "Body"
	var capsule := CylinderShape3D.new()
	capsule.radius = radius
	capsule.height = height
	shape.shape = capsule
	body.add_child(shape)
	return body


## A sphere prop. Bouncier than boxes: it gets a physics material so it reads
## differently the moment it is spawned.
static func build_ball(radius: float, color: Color, mass: float, bounce: float) -> RigidBody3D:
	var body := _body(mass)
	var visual := MeshInstance3D.new()
	visual.name = "Visual"
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	visual.mesh = sphere
	visual.material_override = _material(color, 0.5)
	body.add_child(visual)
	var shape := CollisionShape3D.new()
	shape.name = "Body"
	var ball := SphereShape3D.new()
	ball.radius = radius
	shape.shape = ball
	body.add_child(shape)
	var physics := PhysicsMaterial.new()
	physics.bounce = bounce
	body.physics_material_override = physics
	return body


## A pre-tilted plank that works as a ramp when spawned — a flat collider at a
## fixed inclination, with high friction so props placed on it stay put.
static func build_ramp(width: float, length: float, thickness: float, color: Color, inclination_degrees: float) -> RigidBody3D:
	var body := build_box(Vector3(width, thickness, length), color, 30.0, 0.95)
	var visual := body.get_node("Visual") as MeshInstance3D
	var shape := body.get_node("Body") as CollisionShape3D
	visual.rotation_degrees = Vector3(inclination_degrees, 0.0, 0.0)
	shape.rotation_degrees = Vector3(inclination_degrees, 0.0, 0.0)
	return body


## Freeze feedback: semi-transparent reads as "not of this world now" without
## any custom shader. Re-applied on unfreeze by restoring full opacity.
static func set_frozen_look(prop: RigidBody3D, frozen: bool) -> void:
	var visual := prop.get_node_or_null("Visual") as MeshInstance3D
	if visual != null:
		visual.transparency = 0.45 if frozen else 0.0


static func _body(mass: float) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.mass = mass
	body.collision_layer = 1
	body.collision_mask = 1
	return body


static func _attach_box_shape(body: RigidBody3D, size: Vector3) -> void:
	var shape := CollisionShape3D.new()
	shape.name = "Body"
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)


static func _material(color: Color, roughness: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	return material
