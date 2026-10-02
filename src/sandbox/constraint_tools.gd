extends SandboxTool
class_name ConstraintTool
## The two-shot constraint tools: first click picks anchor A, second click picks
## anchor B, and the joint is built between them. The pending pick is stored as
## body + local point, so it survives the bodies (or the player) moving between
## the two clicks.
##
## Three kinds ship here — weld (rigid), rope (spring), hinge (axis along the
## first click's surface normal). Each is a tiny subclass; the shared state
## machine lives in this base.

## What the second click builds.
var kind: StringName = &"weld"

var _first: Dictionary = {}


func _init(id: StringName = &"", name: String = "", constraint_kind: StringName = &"weld") -> void:
	super._init(id, name)
	kind = constraint_kind


func selected() -> void:
	_first = {}


func deselected() -> void:
	_first = {}


func on_primary(hit: Dictionary) -> void:
	if _first.is_empty():
		_first = SandboxTool.pick_of(hit)
		if not _first.is_empty():
			Events.notify("已选第一点 — 再点一次完成%s" % display_name, Events.NotifyLevel.INFO)
		return
	var second: Dictionary = SandboxTool.pick_of(hit)
	if second.is_empty():
		return
	var first_body: Node3D = SandboxTool.body_of(_first)
	var second_body: Node3D = SandboxTool.body_of(second)
	if first_body == null or second_body == null:
		# The first pick's body was removed between clicks; start over.
		_first = {}
		Events.notify("第一点已失效，请重新选择", Events.NotifyLevel.WARNING)
		return
	if first_body == second_body:
		Events.notify("两个点不能在同一道具上", Events.NotifyLevel.WARNING)
		return
	_build(first_body, _first, second_body, second)
	_first = {}


func on_secondary(_hit: Dictionary) -> void:
	# Right-click cancels the pending first pick — faster than waiting it out.
	_first = {}
	Events.notify("已取消当前选择", Events.NotifyLevel.INFO)


func _build(first_body: Node3D, first: Dictionary, second_body: Node3D, second: Dictionary) -> void:
	var store: ConstraintStore = Services.get_as(&"constraint_store", &"ConstraintStore") as ConstraintStore
	if store == null:
		return
	var point_a: Vector3 = SandboxTool.world_point_of(first)
	var point_b: Vector3 = SandboxTool.world_point_of(second)
	var extra := {}
	var link: Node = null
	match kind:
		&"weld":
			extra = {"anchor": point_a}
			link = store.build_link(&"weld", first_body, second_body, extra)
		&"rope":
			extra = {
				"length": point_a.distance_to(point_b),
				"local_a": first_body.global_transform.affine_inverse() * point_a,
				"local_b": second_body.global_transform.affine_inverse() * point_b,
			}
			link = store.build_link(&"rope", first_body, second_body, extra)
		&"hinge":
			extra = {
				"pivot": point_b,
				"axis": (first.get("normal", Vector3.UP) as Vector3).normalized(),
			}
			link = store.build_link(&"hinge", first_body, second_body, extra)
	if link == null:
		return
	store.register(link, first_body, second_body, kind, extra)
	match kind:
		&"weld":
			Events.notify("已焊接", Events.NotifyLevel.SUCCESS)
		&"rope":
			Events.notify("已连接绳索（%.1f 米）" % float(extra.get("length", 0.0)), Events.NotifyLevel.SUCCESS)
		&"hinge":
			Events.notify("已安装铰链", Events.NotifyLevel.SUCCESS)
