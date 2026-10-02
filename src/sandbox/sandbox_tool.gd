extends RefCounted
class_name SandboxTool
## Base class for tool-gun tools. A tool is *stateful*: constraint tools are
## two-shot (pick A, pick B), instant tools act per click, and any of them may
## carry panel parameters later. The tool gun routes clicks and hands over a
## hit dictionary; everything else is the tool's business.
##
## Registration is the same seam for core and mods: `ModContext.add_tool`
## stores the instance, the tool gun's wheel/menu cycles through them, and
## switching calls `selected()`/`deselected()` so two-shot state can reset.

var tool_id: StringName = &""
var display_name: String = ""


func _init(id: StringName = &"", name: String = "") -> void:
	tool_id = id
	display_name = name


## Called when the tool becomes the held one. Two-shot tools clear their
## pending selection here, so switching tools can never leave a stale first pick.
func selected() -> void:
	pass


## Called when another tool is chosen.
func deselected() -> void:
	pass


## Primary click on a hit. `hit` carries `collider` (Node), `position`
## (Vector3, world) and `normal` (Vector3, world); a click that hit nothing
## is not routed at all — tools that want "clicked at nothing" can override
## `on_primary_missed`.
func on_primary(hit: Dictionary) -> void:
	pass


## Secondary click on a hit. Unused by the built-ins for now (the wrench owns
## freeze); reserved for tools like "pick material" later.
func on_secondary(hit: Dictionary) -> void:
	pass


## Convenience for two-shot tools: the first pick, stored as a body + its
## local-space point so constraints survive the bodies moving between clicks.
static func pick_of(hit: Dictionary) -> Dictionary:
	var collider: Object = hit.get("collider")
	if collider is Node3D:
		var body := collider as Node3D
		var world_point: Vector3 = hit.get("position", body.global_position)
		return {
			"body": body,
			"local_point": body.global_transform.affine_inverse() * world_point,
			"world_point": world_point,
			"normal": hit.get("normal", Vector3.UP),
		}
	return {}


## Resolve a stored pick back to world space (the body may have moved).
static func world_point_of(pick: Dictionary) -> Vector3:
	var body: Variant = pick.get("body")
	if body is Node3D and is_instance_valid(body):
		return (body as Node3D).global_transform * (pick.get("local_point", Vector3.ZERO) as Vector3)
	return pick.get("world_point", Vector3.ZERO)


## The body of a stored pick, or null when it has since been freed.
static func body_of(pick: Dictionary) -> Node3D:
	var body: Variant = pick.get("body")
	if body is Node3D and is_instance_valid(body):
		return body
	return null
