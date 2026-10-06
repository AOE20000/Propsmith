extends Node
## Does the pelvis compensation reach the bone now?
##
## Before this component was a plain node, `_hips_written` recorded a write that
## the engine discarded: the modifier pass rolls the pose back once the
## modification has been applied to the skin. The component's own numbers looked
## healthy the whole time — the drop grew to its ceiling, the bookkeeping matched
## — while the bone never moved. So the number to watch is the one on the bone,
## read from outside, against the number the component believes it wrote.
var _skel: Skeleton3D
var _ik: ModelFootIK
var _model: Node3D
var _hips: int = -1
var _f := 0
var _rows: Array[String] = []
var _rest_y := 0.0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(load("res://src/boot/startup.tscn").instantiate())
	Events.world_ready.connect(_w)

func _w(_x: Node3D) -> void:
	var p := get_tree().get_first_node_in_group(&"player") as Player
	_model = p.get_node_or_null("PlayerModel") as Node3D
	for n: Node in _model.find_children("*", "Skeleton3D", true, false):
		_skel = n as Skeleton3D
		break
	_ik = _model.get_node_or_null("FootIK") as ModelFootIK
	if _ik == null:
		# Fall back to searching, the mount point moved during the diagnosis.
		for n: Node in _model.find_children("*", "SkeletonModifier3D", true, false):
			_ik = n as ModelFootIK
			if _ik != null:
				break
	_hips = _skel.find_bone(&"Hips")
	_rest_y = _skel.get_bone_global_rest(_hips).origin.y
	Input.action_press(&"move_forward")

func _process(_d: float) -> void:
	if _hips < 0:
		return
	Input.action_press(&"move_forward")
	_f += 1
	if _f < 100:
		return
	if _f % 40 == 0:
		_rows.append("[pelvis] f%d bone.y=%.4f global.y=%.4f rest.y=%.4f | drop=%.4f written.y=%.4f base.y=%.4f" % [
			_f, _skel.get_bone_pose_position(_hips).y,
			_skel.get_bone_global_pose(_hips).origin.y, _rest_y,
			_ik._pelvis_current.length(), _ik._hips_written.y, _ik._hips_base.y])
	if _f > 300:
		Input.action_release(&"move_forward")
		for r: String in _rows:
			print(r)
		_summarise()
		get_tree().quit(0)

func _summarise() -> void:
	# The question: does `written` (what the component believes it wrote) match
	# what is actually on the bone? They are equal only if the write survived.
	print("[pelvis] component reports drop_applied=%.4f" % _ik._pelvis_applied)
	print("[pelvis] compare `written.y` with `bone.y` in the rows above: "
		+ "equal means the write landed on the bone")
	# The two configuration facts that make it land, read from the live figure
	# rather than from a fresh instance — `setup` is what sets the priority, and
	# a fresh instance would report the default and quietly pass a broken build.
	print("[pelvis] node class = %s (must not be SkeletonModifier3D)" % _ik.get_class())
	print("[pelvis] process_priority = %d (must be > 0: after the clips)" % _ik.process_priority)
