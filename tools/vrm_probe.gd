extends Node
func _ready() -> void:
	var vrm_path := "res://vrm_samples/Godette_vrm_v4.vrm"
	var configura_path := "res://addons/Configura/!example/character_scenes/example_model.tscn"
	print("[probe] vrm exists=", ResourceLoader.exists(vrm_path, "PackedScene"))
	var vrm_packed := load(vrm_path) as PackedScene
	print("[probe] vrm loaded=", vrm_packed != null)
	if vrm_packed != null:
		var vrm_model := vrm_packed.instantiate() as Node3D
		print("[probe] vrm instantiated=", vrm_model != null)
		if vrm_model != null:
			vrm_model.free()
	print("[probe] configura exists=", ResourceLoader.exists(configura_path, "PackedScene"))
	var config_packed := load(configura_path) as PackedScene
	print("[probe] configura loaded=", config_packed != null)
	if config_packed != null:
		var config_model := config_packed.instantiate() as Node3D
		print("[probe] configura instantiated=", config_model != null)
		if config_model != null:
			config_model.free()
	# 市民共用基准模型端到端（种子参数集 + 按需渲染）
	var citizen := PedestrianAgent.new()
	add_child(citizen)
	var swapped: bool = citizen.apply_base_figure()
	var figure := citizen.get_node_or_null("Figure") as Node3D
	var meshes: int = 0
	var ranged: int = 0
	if figure != null:
		for n: Node in figure.find_children("*", "MeshInstance3D", true, false):
			meshes += 1
			if (n as MeshInstance3D).visibility_range_end > 0.0:
				ranged += 1
	print("[probe] citizen base figure=", swapped, " visual_hidden=", not (citizen.get_node("Visual") as MeshInstance3D).visible,
		" meshes=", meshes, " distance_culled=", ranged)
	citizen.free()
	print("[probe] done")
	get_tree().quit(0)
