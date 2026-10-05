extends Node3D
class_name RopeVisual
## The visible **and physical** half of a rope constraint: a thin bar stretched
## between two (body, local point) pairs, re-aligned every frame, plus the rope
## physics itself — a restoring pull along the line whenever the ends drift
## past the rest length, with damping along it.
##
## Why hand-rolled: this Godot build ships with the Jolt module, which does not
## compile `DampedSpringJoint3D` (verified via ClassDB — the class does not
## exist). A per-frame central force is the honest replacement: it only pulls
## (never pushes, unlike a spring), it sags naturally when slack, and it cannot
## dangle a dangling-reference crash.
##
## Lives under the constraint store; kills itself when either end body is freed.

const THICKNESS: float = 0.04
## How hard the rope pulls per metre of overshoot, per kg — tuned so a rope at
## 2x its length arrests a falling prop in a few frames without launching it.
const STIFFNESS: float = 60.0
## Fraction of along-line relative velocity removed per second at full stretch.
const DAMPING: float = 6.0

## Rest length in metres (the distance the player clicked).
var length: float = 1.0

var _a: Node3D = null
var _local_a: Vector3 = Vector3.ZERO
var _b: Node3D = null
var _local_b: Vector3 = Vector3.ZERO


## Ends are stored as body-local offsets, so the rope tracks props that move,
## spin, or get frozen mid-air.
func bind_ends(a: Node3D, local_a: Vector3, b: Node3D, local_b: Vector3) -> void:
	# The bar's transform is written by hand every rendered frame
	# (`_update_bar`), so the engine's physics interpolation must not also
	# interpolate it — the two writers fight and the rope visibly jitters
	# between its ends.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_a = a
	_local_a = local_a
	_b = b
	_local_b = local_b
	_build_bar()


func _process(_delta: float) -> void:
	if not is_instance_valid(_a) or not is_instance_valid(_b):
		queue_free()
		return
	_update_bar()


func _physics_process(_delta: float) -> void:
	if not is_instance_valid(_a) or not is_instance_valid(_b):
		return
	var body_a := _a as RigidBody3D
	var body_b := _b as RigidBody3D
	if body_a == null or body_b == null:
		# Anchors on static geometry: the rope still renders, it just cannot
		# pull a static world.
		return
	var world_a: Vector3 = _a.global_transform * _local_a
	var world_b: Vector3 = _b.global_transform * _local_b
	var between: Vector3 = world_b - world_a
	var stretch: float = between.length() - length
	if stretch <= 0.0:
		return
	var direction: Vector3 = between / between.length()
	# Equal and opposite pull, scaled by overshoot; both halves of the pair get
	# exactly the force the rope carries, which is what keeps heavy/light pairs
	# honest (the light one accelerates more — real rope behaviour).
	var force: Vector3 = direction * (STIFFNESS * stretch)
	body_a.apply_central_force(force)
	body_b.apply_central_force(-force)
	# Damping along the line only: swinging perpendicular to a taut rope should
	# keep swinging.
	var closing: float = (body_b.linear_velocity - body_a.linear_velocity).dot(direction)
	body_a.apply_central_force(direction * (closing * DAMPING))
	body_b.apply_central_force(-direction * (closing * DAMPING))


func _build_bar() -> void:
	var visual := MeshInstance3D.new()
	visual.name = "RopeBar"
	var box := BoxMesh.new()
	box.size = Vector3(THICKNESS, THICKNESS, 1.0)
	visual.mesh = box
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.45, 0.36, 0.26)
	material.roughness = 0.95
	visual.material_override = material
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(visual)


func _update_bar() -> void:
	var visual := get_node_or_null("RopeBar") as MeshInstance3D
	if visual == null:
		return
	var world_a: Vector3 = _a.global_transform * _local_a
	var world_b: Vector3 = _b.global_transform * _local_b
	var between: Vector3 = world_b - world_a
	var bar_length: float = between.length()
	if bar_length < 0.01:
		visual.visible = false
		return
	visual.visible = true
	# Centre on the midpoint, aim +Z at the far end, stretch to the length.
	global_position = (world_a + world_b) * 0.5
	look_at(world_b, Vector3.UP)
	visual.scale = Vector3(1.0, 1.0, bar_length)
