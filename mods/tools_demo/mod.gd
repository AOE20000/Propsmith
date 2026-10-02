extends ModBase
## The P3 acceptance mod: one of each gameplay face a sandbox mod cares about,
## all through the callback-shaped seams (no extra script files, no class
## inheritance — the same shape a scripted mod uses):
##
##   - add_tool_callbacks  a "mark" tool: clicking a prop paints an emissive
##                         halo on it — two-shot state lives in the callbacks
##   - add_prop_factory    a glowing orb prop
##   - add_npc_factory     a guard NPC (a citizen wearing a different skin)
##
## Everything registered here shows up in the spawn menu, the tool wheel and
## the build panel with zero menu-side changes — that is the P3 contract.

var _marked: Dictionary = {}


func _on_register() -> void:
	display_name = "工具演示"
	version = "1.0.0"
	author = "example"

	context.add_tool_callbacks(&"mark", "标记", {
		"on_primary": _on_mark,
		"on_secondary": func(_hit: Dictionary) -> void:
			_marked.clear()
			Events.notify("标记已清空", Events.NotifyLevel.INFO),
	})
	context.add_prop_factory(&"glow_orb", "发光球", _make_glow_orb)
	context.add_npc_factory(&"guard", "卫兵", _make_guard)

	log_message("已注册：标记工具、发光球道具、卫兵 NPC")


func _on_mark(hit: Dictionary) -> void:
	var collider: Object = hit.get("collider")
	if not (collider is RigidBody3D):
		return
	var prop := collider as RigidBody3D
	var visual := prop.get_node_or_null("Visual") as MeshInstance3D
	if visual == null:
		return
	var key: String = str(prop.get_instance_id())
	if _marked.has(key):
		# Second click on a marked prop: unmark instead of stacking halos.
		visual.material_override = _marked[key] as Material
		_marked.erase(key)
		Events.notify("标记已移除", Events.NotifyLevel.INFO)
		return
	# Built-ins share one material across instances — duplicate before editing
	# or every crate in town glows together.
	visual.material_override = (visual.material_override as Material).duplicate() if visual.material_override != null else StandardMaterial3D.new()
	var material := visual.material_override as StandardMaterial3D
	if material == null:
		return
	material.emission_enabled = true
	material.emission = Color(1.0, 0.62, 0.15)
	material.emission_energy_multiplier = 2.2
	_marked[key] = material
	Events.notify("已标记（再点一次取消）", Events.NotifyLevel.INFO)


func _make_glow_orb() -> RigidBody3D:
	var body: RigidBody3D = PropFactory.build_ball(0.25, Color(1.0, 0.8, 0.3), 3.0, 0.5)
	var visual := body.get_node("Visual") as MeshInstance3D
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(1.0, 0.8, 0.3)
	material.emission_enabled = true
	material.emission = Color(1.0, 0.75, 0.2)
	material.emission_energy_multiplier = 3.0
	visual.material_override = material
	return body


## A citizen in guard colours. Day plan / wandering / damage come with the
## agent — the mod only dresses it.
func _make_guard() -> CharacterBody3D:
	var agent := PedestrianAgent.new()
	var visual := agent.get_node("Visual") as MeshInstance3D
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.22, 0.30, 0.45)
	material.roughness = 0.8
	visual.material_override = material
	return agent


func _on_tick(_delta: float) -> void:
	pass


func serialize() -> Dictionary:
	return {}


func deserialize(_data: Dictionary) -> void:
	pass
