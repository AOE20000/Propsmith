extends RefCounted
class_name Decor
## Code-built scenery for the demo maps: trees, lanterns, benches, stone paths and
## flower clusters.
##
## Same rule as every other builder in this project — primitives assembled in
## code, no imported models — and for the same reason: the scene tree stays
## readable as a diff, and the arrangement is reproducible from the map seed
## rather than frozen into a binary file nobody can review.
##
## ## What this module deliberately does not know
##
## It does not know the map. It builds an object, and it can pick a spot in a zone
## that avoids given rectangles; *which* zones exist, where the pond is and what
## the rooms overlap is the map source's business, passed in as arguments. A decor
## module with "the pond is at z=60" baked into it would be a second copy of the
## ground plan, and the two copies would drift the first time the pond moved.
##
## ## Collision policy
##
## Everything solid sits on layer 1 — the world layer players, props and vehicles
## collide with — and deliberately *not* on `SurfaceQuery.GROUND_MASK`. A tree
## trunk is an obstacle, not ground: a prop spawned on the lawn should still find
## the lawn, not the top of a lantern post. Flowers and path slabs carry no
## collision at all, because their entire job is to be looked at.

## How far inside a zone's edge a scatter is allowed to land. Keeps props from
## growing out of the boundary wall.
const EDGE_CLEARANCE: float = 3.0


## A random point inside `zone`, clear of every rectangle in `reserved` and at
## least `clearance` in from the zone's edges, or `Vector2.INF` when no such spot
## was found in `attempts` tries.
##
## Rejection sampling rather than a hand-written coordinate table: the arrangement
## has to come out identical for the same map seed — that is what makes the world
## reproducible — but no part of it should be a number somebody typed. Returning
## `Vector2.INF` instead of pushing a sample back into the zone is the honest
## failure: a caller that asked for ten trees and got nine should skip one, not be
## handed a tree inside a wall.
static func free_spot(
	zone: Rect2,
	reserved: Array[Rect2],
	rng: RandomNumberGenerator,
	clearance: float = EDGE_CLEARANCE,
	attempts: int = 24,
) -> Vector2:
	var inner: Rect2 = zone.grow(-clearance)
	if inner.size.x <= 0.0 or inner.size.y <= 0.0:
		return Vector2.INF
	for _attempt: int in attempts:
		var spot := Vector2(
			rng.randf_range(inner.position.x, inner.end.x),
			rng.randf_range(inner.position.y, inner.end.y),
		)
		var blocked: bool = false
		for area: Rect2 in reserved:
			if area.has_point(spot):
				blocked = true
				break
		if not blocked:
			return spot
	return Vector2.INF


## A tree: a tapered trunk under a few overlapping canopy balls.
##
## The canopy is deliberately faceted (8 segments, 4 rings) rather than smooth. At
## the distance a tree is seen from here a smooth sphere costs triangles and reads
## as a bush, while a faceted one reads as drawing. Two greens alternate so a stand
## of them does not look like one object stamped ten times — nothing here is
## textured, so the colour *is* the detail.
static func tree(rng: RandomNumberGenerator) -> Node3D:
	var root := Node3D.new()
	root.name = "Tree"
	root.rotation_degrees = Vector3(0.0, rng.randf_range(0.0, 360.0), 0.0)

	var height: float = rng.randf_range(3.2, 5.0)
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.15
	trunk.bottom_radius = 0.26
	trunk.height = height
	trunk.radial_segments = 7
	_part(root, "Trunk", trunk, _material(Color(0.33, 0.25, 0.19), 0.9), Vector3(0.0, height * 0.5, 0.0))

	var leaf := _material(
		Color(0.28, 0.46, 0.20) if rng.randf() < 0.5 else Color(0.17, 0.34, 0.16),
		0.9,
	)
	var blobs: int = rng.randi_range(3, 4)
	for index: int in blobs:
		var rise: float = float(index) / float(maxi(blobs - 1, 1))
		var radius: float = rng.randf_range(1.4, 2.0) * (1.15 - rise * 0.4)
		var ball := SphereMesh.new()
		ball.radius = radius
		ball.height = radius * 2.0
		ball.radial_segments = 8
		ball.rings = 4
		var angle: float = rng.randf_range(0.0, TAU)
		var spread: float = 0.0 if index == 0 else rng.randf_range(0.2, 0.6) * radius
		_part(root, "Canopy%d" % index, ball, leaf, Vector3(
			cos(angle) * spread,
			height + rise * radius * 1.15,
			sin(angle) * spread,
		))

	# Only the trunk is solid. A canopy-sized collider would stop the player a
	# metre short of the tree with nothing visible to explain it.
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.34
	capsule.height = maxf(height * 0.75, 0.7)
	_obstacle(root, capsule, Vector3(0.0, height * 0.38, 0.0))
	return root


## A lamp post: a slim post, an emissive lamp head, and a small warm light.
##
## The light does not cast shadows — six of these with shadow maps would cost more
## than the scene is worth, and a lantern's own shadow is not what makes dusk read.
## It is also always on: in daylight it is invisible, and at dusk it is already
## correct, without the map having to know what time it is.
static func lantern(rng: RandomNumberGenerator) -> Node3D:
	var root := Node3D.new()
	root.name = "Lantern"
	var metal := _material(Color(0.17, 0.16, 0.15), 0.6)
	var height: float = rng.randf_range(2.7, 3.2)

	var post := CylinderMesh.new()
	post.top_radius = 0.06
	post.bottom_radius = 0.09
	post.height = height
	post.radial_segments = 6
	_part(root, "Post", post, metal, Vector3(0.0, height * 0.5, 0.0))

	var cap := CylinderMesh.new()
	cap.top_radius = 0.26
	cap.bottom_radius = 0.07
	cap.height = 0.16
	cap.radial_segments = 6
	_part(root, "Cap", cap, metal, Vector3(0.0, height + 0.32, 0.0))

	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color(1.0, 0.88, 0.62)
	glass.roughness = 0.4
	glass.emission_enabled = true
	glass.emission = Color(1.0, 0.78, 0.42)
	glass.emission_energy_multiplier = 1.8
	var lamp := BoxMesh.new()
	lamp.size = Vector3(0.22, 0.3, 0.22)
	_part(root, "Lamp", lamp, glass, Vector3(0.0, height + 0.1, 0.0))

	var glow := OmniLight3D.new()
	glow.name = "Glow"
	glow.position = Vector3(0.0, height + 0.1, 0.0)
	glow.light_color = Color(1.0, 0.80, 0.48)
	glow.light_energy = 2.2
	glow.omni_range = 7.5
	glow.shadow_enabled = false
	root.add_child(glow)

	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.14
	capsule.height = maxf(height, 0.4)
	_obstacle(root, capsule, Vector3(0.0, height * 0.5, 0.0))
	return root


## A park bench. Faces +Z, so a caller that wants it along a path sets a yaw — the
## builder has no opinion about which way a bench should look.
static func bench(rng: RandomNumberGenerator) -> Node3D:
	var root := Node3D.new()
	root.name = "Bench"
	var length: float = rng.randf_range(1.7, 2.2)
	var wood := _material(Color(0.40, 0.28, 0.18), 0.85)
	var iron := _material(Color(0.19, 0.18, 0.17), 0.5)

	var slats: int = 3
	var slat_width: float = 0.13
	for index: int in slats:
		var slat := BoxMesh.new()
		slat.size = Vector3(length, 0.05, slat_width)
		_part(root, "Seat%d" % index, slat, wood, Vector3(0.0, 0.46, (float(index) - 1.0) * (slat_width + 0.02)))

	for index: int in 2:
		var rail := BoxMesh.new()
		rail.size = Vector3(length, 0.12, 0.05)
		_part(root, "Back%d" % index, rail, wood, Vector3(0.0, 0.68 + float(index) * 0.18, -0.24))

	for side: int in 2:
		var sign: float = -1.0 if side == 0 else 1.0
		var leg := BoxMesh.new()
		leg.size = Vector3(0.08, 0.46, 0.5)
		_part(root, "Leg%d" % side, leg, iron, Vector3(sign * (length * 0.5 - 0.1), 0.23, -0.02))
		var upright := BoxMesh.new()
		upright.size = Vector3(0.08, 0.5, 0.08)
		_part(root, "Upright%d" % side, upright, iron, Vector3(sign * (length * 0.5 - 0.1), 0.71, -0.24))

	var seat := BoxShape3D.new()
	seat.size = Vector3(length, 0.95, 0.55)
	_obstacle(root, seat, Vector3(0.0, 0.48, -0.04))
	return root


## A run of flat slabs along a polyline, and how many were laid.
##
## Non-collidable on purpose: an 8 cm step you can trip over is worse than one you
## cannot, and the ground underneath already answers for the walking surface. The
## slabs are jittered in position and yaw so the run reads as laid by hand.
static func stone_path(
	parent: Node3D,
	points: PackedVector3Array,
	rng: RandomNumberGenerator,
	spacing: float = 1.2,
) -> int:
	if points.size() < 2:
		return 0
	var root := Node3D.new()
	root.name = "Path"
	parent.add_child(root)

	var stone := _material(Color(0.58, 0.57, 0.54), 0.95)
	var laid: int = 0
	for leg: int in points.size() - 1:
		var from: Vector3 = points[leg]
		var to: Vector3 = points[leg + 1]
		var steps: int = maxi(int(from.distance_to(to) / spacing), 1)
		for step: int in steps:
			var at: Vector3 = from.lerp(to, float(step) / float(steps))
			var slab := BoxMesh.new()
			slab.size = Vector3(rng.randf_range(0.72, 0.98), 0.08, rng.randf_range(0.6, 0.82))
			_part(root, "Slab%d" % laid, slab, stone, Vector3(
				at.x + rng.randf_range(-0.12, 0.12),
				0.04,
				at.z + rng.randf_range(-0.12, 0.12),
			), Vector3(0.0, rng.randf_range(-20.0, 20.0), 0.0))
			laid += 1
	return laid


## A handful of stems with coloured heads. A few hues rather than one, because a
## single-colour cluster reads as a bush rather than as flowers.
static func flower_cluster(rng: RandomNumberGenerator) -> Node3D:
	var root := Node3D.new()
	root.name = "Flowers"
	var stem_material := _material(Color(0.22, 0.40, 0.18), 0.9)
	var petals: Array[Color] = [
		Color(0.96, 0.93, 0.87),
		Color(0.96, 0.82, 0.34),
		Color(0.90, 0.54, 0.66),
		Color(0.68, 0.60, 0.90),
	]

	var blooms: int = rng.randi_range(4, 7)
	for index: int in blooms:
		var height: float = rng.randf_range(0.18, 0.36)
		var angle: float = rng.randf_range(0.0, TAU)
		var spread: float = rng.randf_range(0.0, 0.32)
		var x: float = cos(angle) * spread
		var z: float = sin(angle) * spread

		var stem := CylinderMesh.new()
		stem.top_radius = 0.012
		stem.bottom_radius = 0.02
		stem.height = height
		stem.radial_segments = 4
		_part(root, "Stem%d" % index, stem, stem_material, Vector3(x, height * 0.5, z))

		var radius: float = rng.randf_range(0.05, 0.08)
		var head := SphereMesh.new()
		head.radius = radius
		head.height = radius * 2.0
		head.radial_segments = 6
		head.rings = 3
		_part(root, "Bloom%d" % index, head, _material(petals[index % petals.size()], 0.8), Vector3(x, height, z))
	return root


## One mesh, placed. Repeated parts carry an explicit index in their name
## (`Seat0`, `Seat1`, `Canopy2`) rather than all being called `Seat`.
##
## Godot renames a second child to `Seat2` on its own, so either way the tree is
## unique — but the *lookup* differs: an exact-name search for `Seat` then finds
## one node and silently reports a three-slat bench as a one-slat bench, which is
## exactly how this builder's first test run failed. Numbering them here makes the
## names predictable, and a `"Seat*"` pattern counts what was actually built.
static func _part(
	parent: Node3D,
	part_name: String,
	mesh: Mesh,
	material: Material,
	at: Vector3,
	degrees: Vector3 = Vector3.ZERO,
) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = part_name
	instance.mesh = mesh
	instance.material_override = material
	instance.position = at
	instance.rotation_degrees = degrees
	parent.add_child(instance)
	return instance


## A static body on the world layer only — see the collision policy at the top of
## this file for why it is kept off the surface-query mask.
static func _obstacle(parent: Node3D, shape: Shape3D, at: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "Obstacle"
	body.collision_layer = 1
	body.collision_mask = 0
	var collider := CollisionShape3D.new()
	collider.name = "Body"
	collider.shape = shape
	collider.position = at
	body.add_child(collider)
	parent.add_child(body)
	return body


static func _material(color: Color, roughness: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	return material
