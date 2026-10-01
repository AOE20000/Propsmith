extends RefCounted
class_name PoiGeometry
## Procedural landmark geometry, split out of `PoiMarker`.
##
## The split follows a real seam: a marker owns identity and the one-shot discovery
## rule (~60 lines), while this owns five shapes built from primitives (~240 lines).
## They were in one file only because they arrived together, and the geometry is the
## part a mod author is most likely to read and copy when writing an `add_poi_factory`
## — see `mods/lighthouse/mod.gd`, which is exactly that.
##
## Everything here is static and node-agnostic: builders take a root to fill and a
## materials dictionary, and fall back to a sensible default per style when a caller
## supplies nothing. That keeps the caller in charge of colour and the shape in charge
## of silhouette.
##
## Five styles, each readable from a distance and made of primitives, so the world needs
## no additional art dependency: `watchtower`, `ruins`, `campsite`, `crystal`, and
## `cairn` for anything unrecognised.

## Material vocabulary shared by the builders and by mods writing their own landmark
## geometry. These used to live on `PoiMarker`, which meant a mod had to import the
## discovery node to colour a cylinder.

static func standard_material(colour: Color, roughness: float = 0.85) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.roughness = roughness
	return material


static func emissive_material(colour: Color, energy: float = 2.0) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.emission_enabled = true
	material.emission = colour
	material.emission_energy_multiplier = energy
	material.roughness = 0.35
	return material


## Build the geometry for one style. A mod's `add_poi_factory` may ignore this entirely
## and return its own `Node3D`; this is the default the core places.
static func build(style: StringName, materials: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = "Geometry"
	match style:
		&"watchtower":
			_build_watchtower(root, materials)
		&"ruins":
			_build_ruins(root, materials)
		&"campsite":
			_build_campsite(root, materials)
		&"crystal":
			_build_crystal(root, materials)
		_:
			_build_cairn(root, materials)
	return root


static func _mesh_node(mesh: Mesh, material: Material, position: Vector3, scale: Vector3 = Vector3.ONE, rotation_y: float = 0.0) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = material
	node.position = position
	node.scale = scale
	node.rotation.y = rotation_y
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	return node


## A landmark's silhouette also has to be *solid*: touching a watchtower must not walk
## through it. One box collider per mass is cheaper than colliding the visual meshes and
## sufficient at this scale.
static func _static_box(size: Vector3, material: Material, position: Vector3, rotation_y: float = 0.0) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = position
	body.rotation.y = rotation_y
	body.collision_layer = 1
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	var visual := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	visual.mesh = mesh
	visual.material_override = material
	body.add_child(visual)
	return body


static func _build_watchtower(root: Node3D, materials: Dictionary) -> void:
	var stone: Material = materials.get("stone", standard_material(Color(0.45, 0.44, 0.42)))
	var wood: Material = materials.get("wood", standard_material(Color(0.32, 0.22, 0.14)))
	var height: float = 12.0
	var radius: float = 3.2

	var base := CylinderMesh.new()
	base.top_radius = radius
	base.bottom_radius = radius * 1.25
	base.height = 1.0
	base.radial_segments = 10
	root.add_child(_mesh_node(base, stone, Vector3(0.0, 0.5, 0.0)))

	var shaft := CylinderMesh.new()
	shaft.top_radius = radius * 0.72
	shaft.bottom_radius = radius * 0.9
	shaft.height = height
	shaft.radial_segments = 10
	root.add_child(_mesh_node(shaft, stone, Vector3(0.0, height * 0.5 + 1.0, 0.0)))

	var platform := CylinderMesh.new()
	platform.top_radius = radius * 1.15
	platform.bottom_radius = radius * 1.15
	platform.height = 0.6
	platform.radial_segments = 12
	root.add_child(_mesh_node(platform, wood, Vector3(0.0, height + 1.2, 0.0)))

	var roof := CylinderMesh.new()
	roof.top_radius = 0.0
	roof.bottom_radius = radius * 1.4
	roof.height = 2.6
	roof.radial_segments = 8
	root.add_child(_mesh_node(roof, wood, Vector3(0.0, height + 2.8, 0.0)))

	root.add_child(_static_box(Vector3(radius * 1.6, height + 1.0, radius * 1.6), stone, Vector3(0.0, (height + 1.0) * 0.5, 0.0)))


static func _build_ruins(root: Node3D, materials: Dictionary) -> void:
	var stone: Material = materials.get("stone", standard_material(Color(0.5, 0.48, 0.44)))
	var pillar := CylinderMesh.new()
	pillar.top_radius = 0.42
	pillar.bottom_radius = 0.5
	pillar.height = 4.2
	pillar.radial_segments = 8

	# A fixed seed: a landmark must look the same on every run of a given world, so the
	# variation between the nine pillars cannot come from the global RNG.
	var rng := RandomNumberGenerator.new()
	rng.seed = 90210
	var ring_radius: float = 6.0
	for index: int in 9:
		var angle: float = TAU * float(index) / 9.0
		var pillar_height: float = rng.randf_range(1.4, 4.4)
		var local_pillar := CylinderMesh.new()
		local_pillar.top_radius = 0.4
		local_pillar.bottom_radius = 0.5
		local_pillar.height = pillar_height
		local_pillar.radial_segments = 8
		var node := _mesh_node(
			local_pillar, stone,
			Vector3(cos(angle) * ring_radius, pillar_height * 0.5, sin(angle) * ring_radius),
			Vector3.ONE, angle
		)
		root.add_child(node)
		if index % 2 == 0:
			root.add_child(_static_box(Vector3(1.0, pillar_height, 1.0), stone, node.position))

	var lintel := BoxMesh.new()
	lintel.size = Vector3(5.0, 0.7, 1.2)
	root.add_child(_mesh_node(lintel, stone, Vector3(0.0, 4.6, -ring_radius * 0.35), Vector3.ONE, 0.2))

	var altar := BoxMesh.new()
	altar.size = Vector3(2.4, 0.9, 2.4)
	root.add_child(_mesh_node(altar, stone, Vector3(0.0, 0.45, 0.0)))
	root.add_child(_static_box(Vector3(2.4, 0.9, 2.4), stone, Vector3(0.0, 0.45, 0.0)))


static func _build_campsite(root: Node3D, materials: Dictionary) -> void:
	var wood: Material = materials.get("wood", standard_material(Color(0.3, 0.2, 0.13)))
	var cloth: Material = materials.get("cloth", standard_material(Color(0.55, 0.32, 0.24)))
	var ember: Material = materials.get("ember", emissive_material(Color(1.0, 0.55, 0.2), 3.0))

	var tent := PrismMesh.new()
	tent.size = Vector3(3.0, 2.0, 3.4)
	tent.left_to_right = 0.5
	root.add_child(_mesh_node(tent, cloth, Vector3(-3.0, 1.0, 0.0), Vector3.ONE, 0.3))
	root.add_child(_static_box(Vector3(3.0, 2.0, 3.4), cloth, Vector3(-3.0, 1.0, 0.0), 0.3))

	var log_mesh := CylinderMesh.new()
	log_mesh.top_radius = 0.22
	log_mesh.bottom_radius = 0.22
	log_mesh.height = 2.4
	log_mesh.radial_segments = 6
	for index: int in 5:
		var angle: float = TAU * float(index) / 5.0
		var log_node := _mesh_node(
			log_mesh, wood,
			Vector3(cos(angle) * 0.75, 0.24, sin(angle) * 0.75),
			Vector3.ONE, angle
		)
		log_node.rotation.z = deg_to_rad(90.0)
		root.add_child(log_node)

	var fire := SphereMesh.new()
	fire.radius = 0.4
	fire.height = 0.8
	fire.radial_segments = 8
	fire.rings = 4
	root.add_child(_mesh_node(fire, ember, Vector3(0.0, 0.5, 0.0)))

	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.6, 0.3)
	light.light_energy = 2.2
	light.omni_range = 14.0
	light.position = Vector3(0.0, 1.2, 0.0)
	root.add_child(light)


static func _build_crystal(root: Node3D, materials: Dictionary) -> void:
	var crystal: Material = materials.get("crystal", emissive_material(Color(0.35, 0.75, 1.0), 2.4))
	var stone: Material = materials.get("stone", standard_material(Color(0.35, 0.36, 0.4)))
	var rng := RandomNumberGenerator.new()
	rng.seed = 31337

	var base := CylinderMesh.new()
	base.top_radius = 4.0
	base.bottom_radius = 5.0
	base.height = 1.2
	base.radial_segments = 9
	root.add_child(_mesh_node(base, stone, Vector3(0.0, 0.6, 0.0)))
	root.add_child(_static_box(Vector3(8.0, 1.2, 8.0), stone, Vector3(0.0, 0.6, 0.0)))

	for index: int in 6:
		var angle: float = TAU * float(index) / 6.0 + rng.randf_range(-0.3, 0.3)
		var distance: float = rng.randf_range(0.8, 3.2)
		var shard_height: float = rng.randf_range(3.0, 7.5)
		var shard := CylinderMesh.new()
		shard.top_radius = 0.0
		shard.bottom_radius = rng.randf_range(0.5, 1.1)
		shard.height = shard_height
		shard.radial_segments = 5
		var node := _mesh_node(
			shard, crystal,
			Vector3(cos(angle) * distance, shard_height * 0.5 + 0.9, sin(angle) * distance),
			Vector3.ONE, angle
		)
		node.rotation.x = deg_to_rad(rng.randf_range(-12.0, 12.0))
		node.rotation.z = deg_to_rad(rng.randf_range(-12.0, 12.0))
		root.add_child(node)

	var light := OmniLight3D.new()
	light.light_color = Color(0.45, 0.8, 1.0)
	light.light_energy = 3.0
	light.omni_range = 22.0
	light.position = Vector3(0.0, 4.0, 0.0)
	root.add_child(light)


static func _build_cairn(root: Node3D, materials: Dictionary) -> void:
	var stone: Material = materials.get("stone", standard_material(Color(0.44, 0.43, 0.41)))
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var height: float = 0.0
	for index: int in 5:
		var size: float = 1.6 - float(index) * 0.22
		var rock := SphereMesh.new()
		rock.radius = size * 0.5
		rock.height = size * 0.7
		rock.radial_segments = 7
		rock.rings = 4
		height += size * 0.32
		var node := _mesh_node(
			rock, stone,
			Vector3(rng.randf_range(-0.15, 0.15), height, rng.randf_range(-0.15, 0.15)),
			Vector3(1.0, 0.7, 1.0)
		)
		root.add_child(node)
	root.add_child(_static_box(Vector3(1.4, height + 0.6, 1.4), stone, Vector3(0.0, (height + 0.6) * 0.5, 0.0)))
