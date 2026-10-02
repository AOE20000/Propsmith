extends Node
## Dev-only diagnostic: boot the real game headless, then measure what actually
## came out of the CityGML import — mesh count, the city's global AABB, and a few
## sampled transforms. Exists because "2011 collision bodies" and "an empty
## screen" can both be true, and only geometry-level numbers can say which half
## is lying.

func _ready() -> void:
	var packed: PackedScene = load("res://src/boot/startup.tscn")
	add_child(packed.instantiate())
	Events.world_ready.connect(_on_world_ready)


func _on_world_ready(_world: Node3D) -> void:
	# One frame later: the map source's height settle has run by then.
	await get_tree().process_frame
	_measure()


func _measure() -> void:
	var city: Node3D = _find_node(get_tree().root, "City") as Node3D
	if city == null:
		printerr("[diag] no City container found under the boot scene")
		get_tree().quit(1)
		return

	var total: int = 0
	var with_surface: int = 0
	var minimum := Vector3(INF, INF, INF)
	var maximum := -Vector3.INF
	var samples: PackedStringArray = PackedStringArray()
	var stack: Array[Node] = [city]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child: Node in node.get_children():
			stack.append(child)
		if node is MeshInstance3D:
			var mesh_instance := node as MeshInstance3D
			total += 1
			if mesh_instance.mesh == null or mesh_instance.mesh.get_surface_count() == 0:
				continue
			with_surface += 1
			var aabb: AABB = mesh_instance.global_transform * mesh_instance.mesh.get_aabb()
			minimum = minimum.min(aabb.position)
			maximum = maximum.max(aabb.position + aabb.size)
			if samples.size() < 6:
				samples.append("pos=%s aabb_size=%s surfaces=%d vis=%s" % [
					mesh_instance.global_position, aabb.size,
					mesh_instance.mesh.get_surface_count(), mesh_instance.visible,
				])

	print("[diag] city=%s children=%d" % [city.name, city.get_child_count()])
	print("[diag] meshinstances=%d with_surfaces=%d" % [total, with_surface])
	print("[diag] city aabb min=%s max=%s" % [minimum, maximum])
	for sample: String in samples:
		print("[diag]   " + sample)
	get_tree().quit(0)


func _find_node(root: Node, wanted: String) -> Node:
	if root.name == wanted:
		return root
	for child: Node in root.get_children():
		var found: Node = _find_node(child, wanted)
		if found != null:
			return found
	return null
