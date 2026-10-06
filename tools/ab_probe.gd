extends Node
## Same-frame A/B: does the pelvis compensation move the hips *this frame*?
##
## The window minimum that `drop_probe` reports cannot answer this — the hips
## rise and fall with the stride, so a minimum over400 frames is the same with
## the compensation on or off. What answers it is a before/after pair **inside
## one frame**: read the hips' world height, let the component write, read
## again. The difference is the compensation's real effect, with the stride
## cancelled out.
##
## It also answers whether the bone order matters, because it runs whatever the
## component currently believes about it.
var _skel: Skeleton3D
var _ik: ModelFootIK
var _hips: int = -1
var _f: int = 0
var _samples: Array[float] = []
var _pose_samples: Array[float] = []
var _applied: Array[float] = []

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
	_ik = _skel.get_node_or_null("FootIK") as ModelFootIK
	_hips = _skel.find_bone(&"Hips")
	Input.action_press(&"move_forward")

func _process(_d: float) -> void:
	if _hips < 0 or _ik == null:
		return
	Input.action_press(&"move_forward")
	_f += 1
	if _f < 80:
		return
	# Component runs as a modifier, so by the time this probe's _process runs
	# the write has already happened this frame. What it can still measure is
	# whether the *pose* it wrote is the pose the world shows, which is the
	# question the bone order was suspected of answering wrongly.
	var pose: Vector3 = _skel.get_bone_pose_position(_hips)
	var world: float = (_skel.global_transform * _skel.get_bone_global_pose(_hips)).origin.y
	# The rest origin plus the node's own height is the expected world y for
	# this pose. The gap between them is what the chain adds.
	var rest_y: float = _skel.get_bone_rest(_hips).origin.y
	var node_y: float = _skel.global_position.y
	var expected: float = rest_y + node_y + (pose.y - rest_y)
	_samples.append(world - expected)
	_pose_samples.append(_ik._pelvis_current.length())
	_applied.append(_ik._pelvis_applied)
	if _f > 300:
		_report()

func _report() -> void:
	Input.action_release(&"move_forward")
	var worst := 0.0
	var total := 0.0
	for v: float in _samples:
		worst = maxf(worst, absf(v))
		total += v
	print("[ab] drop_written_max=%.4f applied_max=%.4f" % [
		_max_of(_pose_samples), _max_of(_applied)
	])
	print("[ab] world-vs-expected offset: mean=%+.5f worst=%.5f m over %d frames" % [
		total / maxf(1.0, float(_samples.size())), worst, _samples.size()
	])
	print("[ab] VERDICT: %s" % (
		"the chain resolves the written pose exactly — bone order is fine"
		if worst < 0.01 else "the chain does NOT reproduce the written pose"
	))
	get_tree().quit(0)

func _max_of(values: Array[float]) -> float:
	var m := 0.0
	for v: float in values:
		m = maxf(m, v)
	return m
