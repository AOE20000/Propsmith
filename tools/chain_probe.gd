extends Node
## Does the engine's own chain resolution agree with a hand-computed one?
##
## The previous round concluded that the reversed bone order is harmless, and
## the evidence was an offset of 0.00000 m. That measurement compared the hips'
## world position against a value derived from an *assumption* — that the parent
## chain contributes nothing to the hips' height because `Root`'s rest origin is
## `(0, 0, 0)`. So it proved the write was faithful to the assumption and said
## nothing about the assumption.
##
## This removes the assumption. For every bone it computes the global transform
## the documented way — walk the parents, composing the parent's rest and pose
## with the bone's own — and compares that against what the engine reports.
## Then it does the same with a known offset written into the hips, which is
## the case that actually matters: a world-space offset that the component
## believes it is applying.
##
## If the two agree everywhere, the reversed link is genuinely inert and the
## pelvis drop's problem is something else. If they disagree on the hips only
## once an offset is written, then the order does matter and the earlier
## measurement was measuring its own assumption.
##
## Read-only: nothing here writes to the running figure's skeleton beyond the
## one probe offset, which it restores.

var _skel: Skeleton3D
var _hips: int = -1
var _phase: int = 0
var _rest_before: Dictionary = {}
var _pose_before: Vector3


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(load("res://src/boot/startup.tscn").instantiate())
	Events.world_ready.connect(_w)


func _w(_x: Node3D) -> void:
	var p := get_tree().get_first_node_in_group(&"player") as Player
	var m := p.get_node_or_null("PlayerModel") as Node3D
	for n: Node in m.find_children("*", "Skeleton3D", true, false):
		_skel = n as Skeleton3D
		break
	if _skel == null:
		print("[chain-probe] FAIL: no skeleton")
		get_tree().quit(1)
		return
	_hips = _skel.find_bone(&"Hips")
	_phase = 1


func _process(_d: float) -> void:
	match _phase:
		1:
			_capture()
			_phase = 2
		2:
			_report_unposed()
			_write_offset()
			_phase = 3
		3:
			_report_posed()
			_restore()
			get_tree().quit(0)


## Snapshot the whole skeleton so the probe can put it back exactly.
func _capture() -> void:
	_rest_before.clear()
	for i: int in _skel.get_bone_count():
		_rest_before[i] = {
			"rest": _skel.get_bone_rest(i),
			"pose": _skel.get_bone_pose(i),
		}
	_pose_before = _skel.get_bone_pose_position(_hips)


## The documented composition, walked by hand. `parent · child` at each level,
## using the rest for the link and the pose for the bone itself.
func _hand_global(bone: int) -> Transform3D:
	var acc: Transform3D = _skel.get_bone_rest(bone) * _skel.get_bone_pose(bone)
	var parent: int = _skel.get_bone_parent(bone)
	var guard := 0
	while parent >= 0 and guard < 200:
		acc = (_skel.get_bone_rest(parent) * _skel.get_bone_pose(parent)) * acc
		parent = _skel.get_bone_parent(parent)
		guard += 1
	return acc


## Every bone, engine versus hand, at rest. A reversed link that matters would
## show up here as a position gap.
func _report_unposed() -> void:
	var worst_pos := 0.0
	var worst_rot := 0.0
	var worst_at := -1
	for i: int in _skel.get_bone_count():
		var engine: Transform3D = _skel.get_bone_global_pose(i)
		var hand := _hand_global(i)
		var dp: float = (engine.origin - hand.origin).length()
		var dr: float = rad_to_deg(engine.basis.get_rotation_quaternion()
			.angle_to(hand.basis.get_rotation_quaternion()))
		if dp > worst_pos:
			worst_pos = dp
			worst_at = i
		worst_rot = maxf(worst_rot, dr)
	print("[chain-probe] unposed: engine vs hand over %d bones — worst pos %.6f m (%s), worst rot %.4f°" % [
		_skel.get_bone_count(), worst_pos, _skel.get_bone_name(worst_at), worst_rot
	])
	# The hips specifically, with the numbers a reader can check by hand: the
	# rest origin, the parent's rest origin, and where the engine puts them.
	var parent: int = _skel.get_bone_parent(_hips)
	print("[chain-probe] hips: rest origin %s, parent %s rest origin %s" % [
		str(_skel.get_bone_rest(_hips).origin), _skel.get_bone_name(parent),
		str(_skel.get_bone_rest(parent).origin) if parent >= 0 else "<root>"
	])
	print("[chain-probe] hips engine origin %s, hand origin %s" % [
		str(_skel.get_bone_global_pose(_hips).origin), str(_hand_global(_hips).origin)
	])


func _write_offset() -> void:
	_skel.set_bone_pose_position(_hips, _pose_before + Vector3(0.0, -0.10, 0.0))


## The same comparison with the offset in place — the case the pelvis drop is.
func _report_posed() -> void:
	var worst_pos := 0.0
	var worst_at := -1
	for i: int in _skel.get_bone_count():
		var dp: float = (_skel.get_bone_global_pose(i).origin - _hand_global(i).origin).length()
		if dp > worst_pos:
			worst_pos = dp
			worst_at = i
	var hips_engine: float = _skel.get_bone_global_pose(_hips).origin.y
	var hips_hand: float = _hand_global(_hips).origin.y
	var rest_y: float = _skel.get_bone_global_rest(_hips).origin.y
	print("[chain-probe] posed (−0.10 local): worst pos gap %.6f m (%s)" % [
		worst_pos, _skel.get_bone_name(worst_at)
	])
	print("[chain-probe] hips engine y %.5f, hand y %.5f, global rest y %.5f" % [
		hips_engine, hips_hand, rest_y
	])
	print("[chain-probe] ⇒ engine moved %.5f m for a −0.10 write (x%.3f); hand moved %.5f (x%.3f)" % [
		hips_engine - rest_y, (hips_engine - rest_y) / -0.10,
		hips_hand - rest_y, (hips_hand - rest_y) / -0.10,
	])
	print("[chain-probe] VERDICT: %s" % (
		"engine matches the documented composition — the order is inert"
		if worst_pos < 0.002 else
		"engine DIVERGES from the documented composition — the order matters"
	))


func _restore() -> void:
	for i: int in _rest_before.size():
		var saved: Dictionary = _rest_before[i]
		_skel.set_bone_rest(i, saved["rest"] as Transform3D)
		_skel.set_bone_pose(i, saved["pose"] as Transform3D)
