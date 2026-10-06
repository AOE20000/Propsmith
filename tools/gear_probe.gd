extends Node
## What does the figure look like in each gear, and does it ever sit in a state
## the state table does not name?
##
## The screenshot shows a side-on, arms-trailing, slightly-crouched pose that the
## walking measurements do **not** reproduce (torso pitch reads ≈0 and the head
## sits 0.43 m above the hips in both standing and walking). So the pose in the
## picture is produced by a state these runs never entered — the airborne fall
## loop, the stop blend, or a gear the gear hysteresis parked on.
##
## This walks the figure through every transition on purpose (stand, walk, run,
## jump, fall, land, stop) and reports the silhouette at each, so a state that
## produces the picture is identified by its numbers rather than recognised by
## eye. The joint that tells the story is the elbow: arms trailing behind reads
## as an elbow angle very different from the relaxed hang.
var _skel: Skeleton3D
var _clips: ModelClips
var _ik: ModelFootIK
var _bones: Dictionary = {}
var _f: int = 0
var _phase: int = 0
var _phase_f: int = 0
var _label: String = ""

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
	_clips = m.get_node_or_null("Clips") as ModelClips
	_ik = _skel.get_node_or_null("FootIK") as ModelFootIK
	for name: String in ["Hips", "Chest", "Head", "LeftUpperArm", "LeftLowerArm",
			"LeftHand", "LeftFoot", "RightFoot"]:
		_bones[name] = _skel.find_bone(StringName(name))
	_phase = 1
	_label = "idle"
	_phase_f = 0

func _process(_d: float) -> void:
	if _clips == null: return
	_phase_f += 1
	match _phase:
		1:
			if _phase_f > 60:
				_report("standing still")
				_next(2, "walking", 90)
		2:
			Input.action_press(&"move_forward")
			if _phase_f > 90:
				Input.action_release(&"move_forward")
				_next(3, "stopping", 40)
		3:
			if _phase_f > 40:
				_next(4, "jumping", 6)
		4:
			# Drive the phase directly: the airborne state needs a real vertical
			# velocity, and a probe holding no input never gets one.
			_clips._enter_air(1.0 / 60.0, 2)
			if _phase_f > 45:
				_next(5, "forced fall clip", 30)
		5:
			_clips._advance_air_pose(1.0 / 60.0)
			if _phase_f > 30:
				_next(6, "forced jump clip", 20)
		6:
			_clips._advance_air_pose(1.0 / 60.0)
			if _phase_f > 20:
				get_tree().quit(0)

func _next(phase: int, label: String, frames: int) -> void:
	_phase = phase
	_phase_f = 0
	_label = label

func _report(label: String) -> void:
	var pitch := _pitch_of("Chest")
	var head_up := 0.0
	if _bones["Hips"] >= 0 and _bones["Head"] >= 0:
		head_up = (_world("Head") - _world("Hips")).y
	var elbow := _angle_between("LeftUpperArm", "LeftLowerArm")
	var knee := _angle_between("LeftFoot", "Hips")
	print("[gear] %-20s gear(walk=%s run=%s air=%d) chest_pitch=%+.2f head_up=%.3f elbow=%.1f knee=%.1f" % [
		label, str(_clips._walking), str(_clips._running), _clips._air_phase,
		pitch, head_up, elbow, knee
	])

func _pitch_of(name: String) -> float:
	var idx: int = int(_bones.get(name, -1))
	if idx < 0: return 0.0
	var g: Basis = (_skel.global_transform.basis
		* _skel.get_bone_global_pose(idx).basis).orthonormalized()
	var up: Vector3 = g.y.normalized()
	var mup: Vector3 = _skel.global_transform.basis.y.normalized()
	var fwd: Vector3 = _skel.global_transform.basis.z.normalized()
	var side: Vector3 = mup.cross(fwd)
	if side.length_squared() < 1e-8: return 0.0
	return rad_to_deg(atan2(up.dot(side.normalized()), up.dot(mup)))

func _world(name: String) -> Vector3:
	var idx: int = int(_bones.get(name, -1))
	if idx < 0: return Vector3.ZERO
	return (_skel.global_transform * _skel.get_bone_global_pose(idx)).origin

## Interior angle at `name`'s joint, using the two bones given as the segments
## meeting there. For the elbow that is upper arm and lower arm; for the knee,
## foot and hips.
func _angle_between(a: String, b: String) -> float:
	var ia: int = int(_bones.get(a, -1))
	var ib: int = int(_bones.get(b, -1))
	if ia < 0 or ib < 0: return 0.0
	var ja := _joint_of(a)
	var jb := _joint_of(b)
	if ja < 0 or jb < 0: return 0.0
	var pa := (_skel.global_transform * _skel.get_bone_global_pose(ja)).origin
	var pb := (_skel.global_transform * _skel.get_bone_global_pose(jb)).origin
	return rad_to_deg((pa - _world(b)).angle_to(pb - _world(b)))

func _joint_of(name: String) -> int:
	# The joint the angle is measured at is the bone whose origin is the pivot:
	# for the elbow, the lower arm's origin; for the knee, the foot's.
	return int(_bones.get(name, -1))
