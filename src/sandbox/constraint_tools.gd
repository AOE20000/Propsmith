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
	match kind:
		&"weld":
			_build_weld(store, first_body, second_body, point_a)
		&"rope":
			_build_rope(store, first_body, second_body, point_a, point_b)
		&"hinge":
			_build_hinge(store, first_body, second_body, point_b, first.get("normal", Vector3.UP))


func _build_weld(store: ConstraintStore, a: Node3D, b: Node3D, anchor: Vector3) -> void:
	var joint := Generic6DOFJoint3D.new()
	joint.name = "Weld_%d" % (store.count() + 1)
	joint.position = anchor
	# Six axes locked by default: the pair moves as one solid.
	store.register(joint, a, b, &"weld")
	Events.notify("已焊接", Events.NotifyLevel.SUCCESS)


func _build_rope(store: ConstraintStore, a: Node3D, b: Node3D, point_a: Vector3, point_b: Vector3) -> void:
	# Jolt does not ship DampedSpringJoint3D (verified via ClassDB), so the rope
	# is a self-contained link: visual bar plus a per-frame restoring pull.
	var rope := RopeVisual.new()
	rope.name = "Rope_%d" % (store.count() + 1)
	rope.length = point_a.distance_to(point_b)
	rope.bind_ends(a, a.global_transform.affine_inverse() * point_a, b, b.global_transform.affine_inverse() * point_b)
	store.register(rope, a, b, &"rope")
	Events.notify("已连接绳索（%.1f 米）" % rope.length, Events.NotifyLevel.SUCCESS)


func _build_hinge(store: ConstraintStore, a: Node3D, b: Node3D, pivot: Vector3, axis: Vector3) -> void:
	var joint := HingeJoint3D.new()
	joint.name = "Hinge_%d" % (store.count() + 1)
	# The hinge turns around the joint's local Z: aim -Z along the clicked
	# surface normal, so "the face you first clicked" becomes the spin axis.
	joint.look_at_from_position(pivot, pivot + axis.normalized(), Vector3.UP)
	store.register(joint, a, b, &"hinge")
	Events.notify("已安装铰链", Events.NotifyLevel.SUCCESS)
