extends Node
## Does the pelvis drop cause the forward lean, or is the lean the clip's own?
##
## The forward pitch has survived every change so far — including the one that
## made the drop actually reach the bone — so it is very likely not the drop's
## doing. The only way to know is a controlled pair: the same walk, the same
## frames, once with the drop disabled and once with it at its shipped value,
## measuring the same numbers both times.
##
## What is measured, and why each:
##   * **spine pitch** — the chest bone's own +Y against world up. This is the
##     angle the player sees as "leaning forward", and measuring it against world
##     up (not the model's up) means the authored 180° flip cannot hide a lean by
##     inverting the sign.
##   * **hip height above the ground** — the drop's whole purpose. If it does not
##     move, the drop is not reaching the figure and the pitch cannot be its doing.
##   * **knee angle** — the new report shows bent knees at standstill, so the
##     knee is measured too: a hip that has dropped without the knee opening is a
##     crouch, not a weight shift.
##
## The probe takes no side effects beyond pressing forward; run it twice with
## `max_pelvis_drop` set differently and diff the two reports.

const WALK_SECONDS: float = 4.0
const SETTLE_SECONDS: float = 1.2

var _skel: Skeleton3D
var _ik: ModelFootIK
var _hips: int = -1
var _chest: int = -1
var _knees: Array[int] = [-1, -1]
var _ground_y: float = 0.0
var _elapsed: float = 0.0
var _frames: int = 0
var _pitch: Array[float] = []
var _hip_h: Array[float] = []
var _knee: Array[float] = []
var _drop: Array[float] = []
var _ground_hits := 0


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
	_hips = _skel.find_bone(&"Hips")
	_chest = _skel.find_bone(&"Chest")
	_knees[0] = _skel.find_bone(&"LeftLowerLeg")
	_knees[1] = _skel.find_bone(&"RightLowerLeg")
	# One ground reading under the figure, taken once: the terrain is flat where
	# the tests run and re-reading it every frame would only add noise.
	_ground_y = _ground_under(_bone(_hips))
	Input.action_press(&"move_forward")


func _process(_d: float) -> void:
	if _skel == null or _hips < 0:
		return
	Input.action_press(&"move_forward")
	_elapsed += _d
	if _elapsed < SETTLE_SECONDS:
		return
	_frames += 1
	_pitch.append(_spine_pitch())
	_hip_h.append(_bone(_hips).y - _ground_y)
	_knee.append(_worst_knee())
	_drop.append(_ik._pelvis_current.length() if _ik != null else 0.0)
	if is_finite(_ground_under(_bone(_hips))):
		_ground_hits += 1
	if _elapsed >= SETTLE_SECONDS + WALK_SECONDS:
		_report()


## The chest bone's pitch from vertical, in degrees, positive = leaning forward.
## Measured against world up so the model's authored yaw and the 180° flip are
## both irrelevant: this is the angle a camera would see.
func _spine_pitch() -> float:
	var basis: Basis = _skel.global_transform.basis * _skel.get_bone_global_pose(_chest).basis
	var up: Vector3 = basis.y.normalized()
	# acos, not asin: a rotation about X or Z leaves the y component near 1 while
	# still laying the bone over, so asin would report a horizontal spine as upright.
	return rad_to_deg(acos(clampf(up.dot(Vector3.UP), -1.0, 1.0)))


## Interior angle at whichever knee is straighter — 180° is a straight leg, and a
## knee that stays bent while the figure stands is its own report.
func _worst_knee() -> float:
	var straightest := 0.0
	for side: int in 2:
		var knee: int = _knees[side]
		if knee < 0:
			continue
		var upper: int = _skel.get_bone_parent(knee)
		var lower: int = _skel.get_bone_children(knee)[0] if _skel.get_bone_children(knee).size() > 0 else -1
		if upper < 0 or lower < 0:
			continue
		var a: Vector3 = _bone(upper) - _bone(knee)
		var b: Vector3 = _bone(lower) - _bone(knee)
		if a.length_squared() < 1e-8 or b.length_squared() < 1e-8:
			continue
		straightest = maxf(straightest, rad_to_deg(a.angle_to(b)))
	return straightest


func _bone(index: int) -> Vector3:
	return (_skel.global_transform * _skel.get_bone_global_pose(index)).origin


func _ground_under(from: Vector3) -> float:
	var space := _skel.get_world_3d().direct_space_state
	if space == null:
		return 0.0
	var query := PhysicsRayQueryParameters3D.create(
		from + Vector3.UP * 0.3, from - Vector3.UP * 1.2, 1)
	var hit: Dictionary = space.intersect_ray(query)
	return (hit["position"] as Vector3).y if not hit.is_empty() else NAN


func _report() -> void:
	Input.action_release(&"move_forward")
	print("[ab] ==== max_pelvis_drop = %.3f ====" % (_ik.max_pelvis_drop if _ik != null else -1.0))
	print("[ab] drop actually applied: %.4f..%.4f m" % [_min(_drop), _max(_drop)])
	print("[ab] spine pitch:mean %+.1f°  range %.1f..%.1f" % [
		_mean(_pitch), _min(_pitch), _max(_pitch)])
	print("[ab] hip height above ground: %.4f..%.4f m" % [_min(_hip_h), _max(_hip_h)])
	print("[ab] knee angle: %.1f..%.1f° (180 = straight)" % [_min(_knee), _max(_knee)])
	get_tree().quit(0)


func _min(a: Array) -> float:
	var m := INF
	for v: float in a:
		m = minf(m, v)
	return m


func _max(a: Array) -> float:
	var m := -INF
	for v: float in a:
		m = maxf(m, v)
	return m


func _mean(a: Array) -> float:
	var t := 0.0
	for v: float in a:
		t += v
	return t / maxf(1.0, float(a.size()))
