extends Node
## The planted-leg shortfall measured against the drop that is supposed to cover
## it, frame by frame, so the two can be compared rather than assumed equal.
##
## Measured: a planted leg is short by 0.0075-0.1103 m, and max_pelvis_drop is
## 0.12. So the drop is *sized* for this shortfall — the bent knee the playtest
## reports is the compensation doing its job. The question is whether covering
## the whole shortfall with pelvis motion is the right way to buy thatreach, or
## whether the knee should take part of it instead.
var _skel: Skeleton3D
var _ik: ModelFootIK
var _f := 0
var _short: Array[float] = []
var _drop: Array[float] = []
var _knee: Array[float] = []

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
	_ik = m.get_node_or_null("FootIK") as ModelFootIK
	Input.action_press(&"move_forward")
func _process(_d: float) -> void:
	if _skel == null: return
	Input.action_press(&"move_forward")
	_f += 1
	if _f < 90: return
	if not _ik._planted[0]: 
		if _f > 300:
			Input.action_release(&"move_forward"); _report(); get_tree().quit(0)
		return
	var ch: Dictionary = _ik._chains[0]
	var up: int = ch["upper"]
	var lo: int = ch["lower"]
	var ft: int = ch["foot"]
	var span: float = _ik._rest_length(up, lo) + _ik._rest_length(lo, ft)
	var reach: float = (_ik._plant_pos[0] - _bone(up)).length()
	_short.append(span - reach)
	_drop.append(_ik._pelvis_current.length())
	_knee.append(_knee_deg(up, lo, ft))
	if _f > 300:
		Input.action_release(&"move_forward"); _report(); get_tree().quit(0)
func _report() -> void:
	if _short.is_empty():
		print("[gap] the left foot never planted in the sample")
		return
	print("[gap] planted frames: %d" % _short.size())
	print("[gap] leg shortfall:%.4f..%.4f m" % [_min(_short), _max(_short)])
	print("[gap] drop applied:     %.4f..%.4f m" % [_min(_drop), _max(_drop)])
	print("[gap] knee angle:       %.1f..%.1f°" % [_min(_knee), _max(_knee)])
	print("[gap] ⇒ the drop is %.0f%% of the shortfall it covers" % (
		100.0 * _mean(_drop) / maxf(0.0001, _mean(_short))))
func _knee_deg(up: int, lo: int, ft: int) -> float:
	var a: Vector3 = _bone(up) - _bone(lo)
	var b: Vector3 = _bone(ft) - _bone(lo)
	if a.length_squared() < 1e-8 or b.length_squared() < 1e-8: return 0.0
	return rad_to_deg(a.angle_to(b))
func _bone(i: int) -> Vector3:
	return (_skel.global_transform * _skel.get_bone_global_pose(i)).origin
func _min(a: Array) -> float:
	var m := INF
	for v: float in a: m = minf(m, v)
	return m
func _max(a: Array) -> float:
	var m := -INF
	for v: float in a: m = maxf(m, v)
	return m
func _mean(a: Array) -> float:
	var t := 0.0
	for v: float in a: t += v
	return t / maxf(1.0, float(a.size()))
