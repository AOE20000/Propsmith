extends SandboxTool
class_name PropTool
## Instant-action tools: one click, one effect, no two-shot state.
##
##   - remover: delete the aimed prop (through the spawner, so the undo stack
##     and the constraint store both learn about it)
##   - painter: recolour the aimed prop (its material is duplicated first, so
##     props built from shared materials don't all change together)
##   - weight: cycle a prop's mass through a small ladder
##   - duplicator: respawn a copy of the aimed prop's definition at the aim
##     point (single props for now; welded groups arrive with blueprint saves)

## Which instant action this instance performs.
var action: StringName = &"remover"

const MASS_LADDER: Array[float] = [2.0, 8.0, 20.0, 80.0, 400.0]
const PAINT_COLORS: Array[Color] = [
	Color(0.85, 0.32, 0.28), Color(0.30, 0.55, 0.85), Color(0.36, 0.72, 0.35),
	Color(0.92, 0.75, 0.30), Color(0.88, 0.88, 0.88), Color(0.16, 0.16, 0.18),
]

var _paint_index: int = 0
var _mass_index: int = 0


func _init(id: StringName = &"", name: String = "", tool_action: StringName = &"remover") -> void:
	super._init(id, name)
	action = tool_action


func on_primary(hit: Dictionary) -> void:
	var collider: Object = hit.get("collider")
	if not (collider is RigidBody3D):
		return
	var prop := collider as RigidBody3D
	match action:
		&"remover":
			_remove(prop)
		&"painter":
			_paint(prop)
		&"weight":
			_reweight(prop)
		&"duplicator":
			_duplicate(prop, hit)


func _remove(prop: RigidBody3D) -> void:
	var spawner: PropSpawner = Services.get_as(&"prop_spawner", &"PropSpawner") as PropSpawner
	if spawner != null:
		spawner.remove(prop)
		Events.notify("已移除", Events.NotifyLevel.INFO)


func _paint(prop: RigidBody3D) -> void:
	var visual := prop.get_node_or_null("Visual") as MeshInstance3D
	if visual == null:
		return
	# Built-ins share one material_override across every instance of the same
	# prop — duplicating before editing is what keeps the recolour local.
	visual.material_override = (visual.material_override as Material).duplicate() if visual.material_override != null else StandardMaterial3D.new()
	var material := visual.material_override as StandardMaterial3D
	if material == null:
		return
	material.albedo_color = PAINT_COLORS[_paint_index % PAINT_COLORS.size()]
	_paint_index += 1
	Events.notify("已上色", Events.NotifyLevel.INFO)


func _reweight(prop: RigidBody3D) -> void:
	# Advance to the next mass strictly above the current one, wrapping — the
	# ladder is the whole UI, so "click until it feels right" is the interface.
	var current: float = prop.mass
	var next: float = MASS_LADDER[0]
	for candidate: float in MASS_LADDER:
		if candidate > current * 1.01:
			next = candidate
			break
	prop.mass = next
	Events.notify("质量 %.0f kg" % next, Events.NotifyLevel.INFO)


func _duplicate(prop: RigidBody3D, hit: Dictionary) -> void:
	# The id rides in metadata (set at spawn time); the node name is not an
	# identity — same-named siblings get silently renamed by the tree.
	var source_id: StringName = prop.get_meta(&"prop_id", &"")
	if source_id == &"":
		Events.notify("该道具无法复制（缺少目录标识）", Events.NotifyLevel.WARNING)
		return
	var spawner: PropSpawner = Services.get_as(&"prop_spawner", &"PropSpawner") as PropSpawner
	if spawner == null:
		return
	var normal: Vector3 = hit.get("normal", Vector3.UP)
	var target: Vector3 = hit.get("position", prop.global_position) + normal * 0.6
	var copy: RigidBody3D = spawner.spawn(source_id, target)
	if copy != null:
		copy.rotation = prop.rotation
		Events.notify("已复制", Events.NotifyLevel.INFO)
