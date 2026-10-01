extends RefCounted
class_name WorldScatter
## Deterministic placement of vegetation and rocks.
##
## Placement is a jittered grid seeded by the world seed: each candidate cell
## produces at most one prop, so density is a spacing in metres rather than a
## probability, and two runs of the same seed produce the identical island.
## Cores are not spent on rejection sampling, so a tight budget still yields a
## predictable, evenly covered result.
##
## Props that need collision become individual `MeshInstance3D` nodes; everything
## else is one `MultiMeshInstance3D` per kind, which is what makes thousands of
## grass tufts affordable.
##
## This file is only *how* to scatter. *What* to scatter — the built-in conifer,
## broadleaf, bush, grass and rock kinds, with their spacing and slope limits — lives in
## `PropCatalog`, and mod-registered props arrive through `context.add_prop_factory`.

## The kinds to place, in the order they were registered. Seeded from `PropCatalog` and
## appended to as mods contribute.
var kinds: Array[PropCatalog.PropKind] = []

var _placed_counts: Dictionary = {}


func _init() -> void:
	kinds = PropCatalog.core_kinds()


## Scatter every kind under `parent`. Returns a per-kind instance count for the
## debug overlay. Mod-registered props are appended as extra kinds.
func scatter(parent: Node3D, query: TerrainQuery, config: TerrainConfig) -> Dictionary:
	_placed_counts.clear()
	_append_mod_kinds()

	var container: Node3D = Node3D.new()
	container.name = "Scatter"
	parent.add_child(container)

	for kind: PropCatalog.PropKind in kinds:
		var count: int = _scatter_kind(container, kind, query, config)
		_placed_counts[String(kind.id)] = count
	return _placed_counts


## Turn every prop factory a mod registered into a scatterable kind.
##
## A mod supplies density in metres-per-instance terms and its own slope limit; every
## other parameter stays at the `PropKind` default, which is why a mod prop scatters as
## a modest, evenly spaced feature rather than a carpet.
func _append_mod_kinds() -> void:
	var ordered: Array[Dictionary] = ModHost.content_ordered(&"prop")
	for entry: Dictionary in ordered:
		var factory: Callable = entry.get("factory", Callable())
		if not factory.is_valid():
			continue
		var produced: Variant = factory.call()
		if not (produced is Mesh):
			push_warning("WorldScatter: prop factory '%s' did not return a Mesh" % entry.get("id", "?"))
			continue
		var kind := PropCatalog.PropKind.new()
		kind.id = StringName(String(entry.get("id", "mod_prop")))
		kind.mesh = produced
		kind.material = PropFactory.make_material(Color(0.3, 0.3, 0.3), Color(0.4, 0.45, 0.35))
		kind.spacing = clampf(24.0 / maxf(float(entry.get("density", 1.0)), 0.05), 4.0, 200.0)
		kind.max_slope_degrees = float(entry.get("max_slope_degrees", 35.0))
		kinds.append(kind)


func _scatter_kind(container: Node3D, kind: PropCatalog.PropKind, query: TerrainQuery, config: TerrainConfig) -> int:
	if kind.mesh == null:
		return 0

	var half_extent: int = int(ceil(config.island_radius / kind.spacing)) + 1
	var transforms: Array[Transform3D] = []
	var rng := RandomNumberGenerator.new()

	for cell_z: int in range(-half_extent, half_extent + 1):
		for cell_x: int in range(-half_extent, half_extent + 1):
			if transforms.size() >= kind.max_instances:
				break
			# A stable per-cell seed keeps placement independent of iteration order.
			rng.seed = _cell_seed(config.seed, kind.id, cell_x, cell_z)
			if rng.randf() < kind.skip_ratio:
				continue
			var x: float = (float(cell_x) + rng.randf()) * kind.spacing
			var z: float = (float(cell_z) + rng.randf()) * kind.spacing
			var height: float = query.height_at(x, z)
			if height < kind.min_height:
				continue
			if not query.is_placeable(x, z, kind.max_slope_degrees):
				continue
			if kind.interior_bias > 0.0 and query.island_falloff(x, z) < kind.interior_bias:
				continue
			var scale: float = rng.randf_range(kind.min_scale, kind.max_scale)
			transforms.append(_placement_transform(query, Vector3(x, height, z), scale, rng.randf() * TAU))

	if transforms.is_empty():
		return 0

	if kind.collidable:
		_build_collidable(container, kind, transforms)
	else:
		_build_multimesh(container, kind, transforms)
	return transforms.size()


## A surface-aligned transform: props sit flush against the slope instead of
## standing vertically on a hill.
func _placement_transform(query: TerrainQuery, position: Vector3, scale: float, yaw: float) -> Transform3D:
	var normal: Vector3 = query.normal_at(position.x, position.z)
	var reference := Vector3(sin(yaw), 0.0, cos(yaw))
	var right: Vector3 = normal.cross(reference)
	if right.length_squared() < 0.0001:
		right = normal.cross(Vector3.RIGHT)
	right = right.normalized()
	var forward: Vector3 = right.cross(normal).normalized()
	var basis := Basis(right, normal, forward).scaled(Vector3(scale, scale, scale))
	return Transform3D(basis, position)


func _build_multimesh(container: Node3D, kind: PropCatalog.PropKind, transforms: Array[Transform3D]) -> void:
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = kind.mesh
	multimesh.instance_count = transforms.size()

	var bounds := AABB()
	for index: int in transforms.size():
		var transform: Transform3D = transforms[index]
		multimesh.set_instance_transform(index, transform)
		var point: Vector3 = transform.origin
		bounds = bounds.expand(point) if index > 0 else AABB(point, Vector3.ZERO)

	var mesh_size: Vector3 = kind.mesh.get_aabb().size
	bounds = bounds.grow(maxf(mesh_size.x, maxf(mesh_size.y, mesh_size.z)))

	var instance := MultiMeshInstance3D.new()
	instance.name = String(kind.id)
	instance.multimesh = multimesh
	instance.material_override = kind.material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	instance.custom_aabb = bounds
	container.add_child(instance)


## Collidable props are individual nodes, so physics can actually stop the player.
func _build_collidable(container: Node3D, kind: PropCatalog.PropKind, transforms: Array[Transform3D]) -> void:
	var group := Node3D.new()
	group.name = String(kind.id)
	container.add_child(group)

	for transform: Transform3D in transforms:
		var body := StaticBody3D.new()
		body.transform = transform
		var visual := MeshInstance3D.new()
		visual.mesh = kind.mesh
		visual.material_override = kind.material
		body.add_child(visual)

		var shape := CollisionShape3D.new()
		var mesh_aabb: AABB = kind.mesh.get_aabb()
		var box := BoxShape3D.new()
		# A box around the mesh is cheaper and steadier than a trimesh at this size.
		box.size = Vector3(
			maxf(mesh_aabb.size.x, 0.2),
			maxf(mesh_aabb.size.y, 0.2),
			maxf(mesh_aabb.size.z, 0.2)
		)
		shape.shape = box
		shape.position = mesh_aabb.get_center()
		body.add_child(shape)
		body.collision_layer = 1
		body.collision_mask = 0
		group.add_child(body)


## Stable hash of (world seed, kind, cell) so each cell's jitter is reproducible
## without storing per-cell state.
func _cell_seed(world_seed: int, kind_id: StringName, cell_x: int, cell_z: int) -> int:
	var hash_value: int = world_seed
	hash_value = hash_value * 31 + hash(String(kind_id))
	hash_value = hash_value * 31 + cell_x
	hash_value = hash_value * 31 + cell_z
	return absi(hash_value)


func counts() -> Dictionary:
	return _placed_counts
