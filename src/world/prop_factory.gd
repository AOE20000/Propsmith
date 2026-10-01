extends RefCounted
class_name PropFactory
## Builds the meshes scattered over the island.
##
## Two deliberate choices keep this cheap:
##   - A prop is ONE mesh with vertex colours rather than a tree of nodes, so a
##     single `MultiMeshInstance3D` can hold hundreds of copies with one material
##     and one draw submission. The material reads the green channel to pick the
##     trunk/foliage (or rock/shadowed-rock) colour.
##   - Meshes are generated in code, so the world has no art dependency beyond
##     the CC0 textures and rock models that ship in `assets/`.

## Material for a generated prop. Returned as Material so callers can assign it
## to either a MultiMesh surface or a MeshInstance3D.
static func make_material(primary: Color, secondary: Color, roughness: float = 0.85) -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec3 primary_color : source_color = vec3(0.35, 0.28, 0.2);
uniform vec3 secondary_color : source_color = vec3(0.2, 0.45, 0.2);
uniform float roughness_value = 0.85;

void fragment() {
	float blend = clamp(COLOR.g, 0.0, 1.0);
	vec3 base = mix(primary_color, secondary_color, blend);
	base *= mix(0.86, 1.06, clamp(COLOR.r, 0.0, 1.0));
	ALBEDO = base;
	ROUGHNESS = roughness_value;
	SPECULAR = 0.15;
}
"""
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("primary_color", primary)
	material.set_shader_parameter("secondary_color", secondary)
	material.set_shader_parameter("roughness_value", roughness)
	return material


## Paint a mesh's vertices so `blend` (0 = primary, 1 = secondary) and `shade`
## (0..1 brightness variation) survive into the shader.
static func paint(mesh: ArrayMesh, blend: float, shade: float) -> ArrayMesh:
	var arrays: Array = mesh.surface_get_arrays(0)
	var colors: PackedColorArray = PackedColorArray()
	var vertex_count: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	colors.resize(vertex_count)
	for index: int in vertex_count:
		colors[index] = Color(shade, blend, 0.0, 1.0)
	arrays[Mesh.ARRAY_COLOR] = colors
	var painted := ArrayMesh.new()
	painted.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return painted


## A conifer: tapered trunk plus three stacked cones. Cheap, readable at range,
## and distinctive enough that the island reads as forested from a distance.
static func make_conifer(height: float = 7.0, radius: float = 1.6) -> ArrayMesh:
	var trunk_height: float = height * 0.34
	var trunk := CylinderMesh.new()
	trunk.top_radius = height * 0.018
	trunk.bottom_radius = height * 0.032
	trunk.height = trunk_height
	trunk.radial_segments = 6
	trunk.rings = 1
	trunk.cap_top = false
	trunk.cap_bottom = false
	var trunk_mesh: ArrayMesh = trunk.create_mesh() if trunk.has_method("create_mesh") else _mesh_from_primitive(trunk)
	var painted_trunk: ArrayMesh = paint(trunk_mesh, 0.0, 0.45)

	var merged: ArrayMesh = painted_trunk
	var tiers: int = 3
	for tier: int in tiers:
		var tier_ratio: float = float(tier) / float(tiers)
		var cone := CylinderMesh.new()
		cone.top_radius = 0.0
		cone.bottom_radius = radius * (1.0 - tier_ratio * 0.42)
		cone.height = height * (0.42 - tier_ratio * 0.08)
		cone.radial_segments = 7
		cone.rings = 0
		cone.cap_top = false
		cone.cap_bottom = false
		var cone_mesh: ArrayMesh = _mesh_from_primitive(cone)
		var painted_cone: ArrayMesh = paint(cone_mesh, 1.0, 0.55 + float(tier) * 0.14)
		painted_cone = _translate_mesh(painted_cone, Vector3(0.0, trunk_height + cone.height * 0.34 + float(tier) * height * 0.19, 0.0))
		merged = _merge_meshes(merged, painted_cone)
	return merged


## A broadleaf: short trunk plus a squashed sphere canopy.
static func make_broadleaf(height: float = 5.0, radius: float = 2.2) -> ArrayMesh:
	var trunk := CylinderMesh.new()
	trunk.top_radius = height * 0.02
	trunk.bottom_radius = height * 0.04
	trunk.height = height * 0.42
	trunk.radial_segments = 6
	trunk.rings = 1
	trunk.cap_top = false
	trunk.cap_bottom = false
	var painted_trunk: ArrayMesh = paint(_mesh_from_primitive(trunk), 0.0, 0.42)

	var canopy := SphereMesh.new()
	canopy.radius = radius
	canopy.height = radius * 1.5
	canopy.radial_segments = 8
	canopy.rings = 4
	var painted_canopy: ArrayMesh = paint(_mesh_from_primitive(canopy), 1.0, 0.6)
	painted_canopy = _translate_mesh(painted_canopy, Vector3(0.0, height * 0.42 + radius * 0.5, 0.0))
	return _merge_meshes(painted_trunk, painted_canopy)


## A low bush: two flattened spheres, used to break up empty ground.
static func make_bush(radius: float = 0.9) -> ArrayMesh:
	var lower := SphereMesh.new()
	lower.radius = radius
	lower.height = radius * 1.1
	lower.radial_segments = 6
	lower.rings = 3
	var lower_mesh: ArrayMesh = paint(_mesh_from_primitive(lower), 1.0, 0.5)

	var upper := SphereMesh.new()
	upper.radius = radius * 0.62
	upper.height = radius * 0.8
	upper.radial_segments = 6
	upper.rings = 3
	var upper_mesh: ArrayMesh = _translate_mesh(
		paint(_mesh_from_primitive(upper), 1.0, 0.72),
		Vector3(radius * 0.35, radius * 0.45, radius * 0.2)
	)
	return _merge_meshes(lower_mesh, upper_mesh)


## A grass tuft: three crossed quads. Placed in bulk to give the ground texture.
static func make_grass_tuft(height: float = 0.65) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	var half: float = 0.28
	for blade: int in 3:
		var angle: float = float(blade) * PI / 3.0
		var direction := Vector3(cos(angle), 0.0, sin(angle)) * half
		var local_height: float = height * (0.75 + 0.25 * float(blade % 2))
		vertices.append(-direction)
		vertices.append(direction)
		vertices.append(direction + Vector3(0.0, local_height, 0.0))
		vertices.append(-direction + Vector3(0.0, local_height, 0.0))
		for _i: int in 4:
			colors.append(Color(0.35 + 0.2 * float(blade % 2), 1.0, 0.0, 1.0))
	var indices := PackedInt32Array()
	for blade: int in 3:
		var base: int = blade * 4
		indices.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## CC0 rock model, wrapped as a scatterable prop. Returns an empty array when the
## asset is missing, so a checkout without the models still builds a world.
static func load_model_meshes(model_path: String) -> Array[Mesh]:
	var meshes: Array[Mesh] = []
	if not ResourceLoader.exists(model_path):
		return meshes
	var packed: Resource = load(model_path)
	if not (packed is PackedScene):
		return meshes
	var instance: Node = (packed as PackedScene).instantiate()
	if instance == null:
		return meshes
	_collect_meshes(instance, meshes)
	instance.free()
	return meshes


static func _collect_meshes(node: Node, out: Array[Mesh]) -> void:
	if node is MeshInstance3D:
		var mesh_instance: MeshInstance3D = node
		if mesh_instance.mesh != null:
			out.append(mesh_instance.mesh)
	for child: Node in node.get_children():
		_collect_meshes(child, out)


## Convert a `PrimitiveMesh` into an `ArrayMesh`, which is the form the merge and
## vertex-paint helpers work on. `PrimitiveMesh.surface_get_arrays(0)` returns the
## raw surface arrays; there is no `get_mesh()` in Godot 4.
static func _mesh_from_primitive(primitive: PrimitiveMesh) -> ArrayMesh:
	var arrays: Array = primitive.surface_get_arrays(0)
	if arrays == null or arrays.size() < Mesh.ARRAY_MAX:
		push_error("PropFactory: primitive produced no surface arrays")
		return ArrayMesh.new()
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Append `source` into `target`, remapping indices. Vertices keep their colour
## arrays so the vertex-colour shader keeps working after the merge.
static func _merge_meshes(target: ArrayMesh, source: ArrayMesh) -> ArrayMesh:
	var target_arrays: Array = target.surface_get_arrays(0)
	var source_arrays: Array = source.surface_get_arrays(0)

	var target_vertices: PackedVector3Array = target_arrays[Mesh.ARRAY_VERTEX]
	var source_vertices: PackedVector3Array = source_arrays[Mesh.ARRAY_VERTEX]
	var target_normals: PackedVector3Array = target_arrays[Mesh.ARRAY_NORMAL]
	var source_normals: PackedVector3Array = source_arrays[Mesh.ARRAY_NORMAL]

	var offset: int = target_vertices.size()
	var merged_vertices := target_vertices.duplicate()
	merged_vertices.append_array(source_vertices)
	var merged_normals := target_normals.duplicate()
	merged_normals.append_array(source_normals)

	var merged_colors: PackedColorArray = PackedColorArray()
	if target_arrays[Mesh.ARRAY_COLOR] != null:
		merged_colors = (target_arrays[Mesh.ARRAY_COLOR] as PackedColorArray).duplicate()
	else:
		merged_colors.resize(offset)
	if source_arrays[Mesh.ARRAY_COLOR] != null:
		merged_colors.append_array(source_arrays[Mesh.ARRAY_COLOR] as PackedColorArray)
	else:
		var filler: PackedColorArray = PackedColorArray()
		filler.resize(source_vertices.size())
		merged_colors.append_array(filler)

	var merged_indices := PackedInt32Array()
	if target_arrays[Mesh.ARRAY_INDEX] != null:
		merged_indices = (target_arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).duplicate()
	else:
		for index: int in offset:
			merged_indices.append(index)
	if source_arrays[Mesh.ARRAY_INDEX] != null:
		for index: int in (source_arrays[Mesh.ARRAY_INDEX] as PackedInt32Array):
			merged_indices.append(index + offset)
	else:
		for index: int in source_vertices.size():
			merged_indices.append(index + offset)

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = merged_vertices
	arrays[Mesh.ARRAY_NORMAL] = merged_normals
	arrays[Mesh.ARRAY_COLOR] = merged_colors
	arrays[Mesh.ARRAY_INDEX] = merged_indices
	var merged := ArrayMesh.new()
	merged.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return merged


static func _translate_mesh(mesh: ArrayMesh, offset: Vector3) -> ArrayMesh:
	var arrays: Array = mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var moved := PackedVector3Array()
	moved.resize(vertices.size())
	for index: int in vertices.size():
		moved[index] = vertices[index] + offset
	arrays[Mesh.ARRAY_VERTEX] = moved
	var result := ArrayMesh.new()
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return result
