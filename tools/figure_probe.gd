extends Node
## Where every part of the figure actually is, in one frame, standing still.
##
## The screenshot shows a torso pitched forward with the arms trailing behind.
## Three writers can rotate a bone — the locomotion clip, `ModelStance`'s arm
## aim, and `ModelLean` on the chest — and a screenshot cannot say which. This
## reads the world positions of the joints that define the silhouette (head,
## chest, hands, hips, feet) and the angles between them, so the shape is
## described by numbers rather than by a guess. It then reports the chain from
## the hips upward, because a forward pitch is a *chain* result: whichever joint
## first stops pointing up is where the pitch is introduced.
##
## Read-only, and it works standing or walking depending on `WALK`.

const WALK: bool = true
const SECONDS: float = 3.0

var _skel: Skeleton3D
var _f: int = 0
var _bones: Dictionary = {}
var _worst: Dictionary = {}
var _samples: Array[Dictionary] = []

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
	for name: String in ["Hips", "Spine", "Chest", "Neck", "Head",
			"LeftShoulder", "LeftUpperArm", "LeftLowerArm", "LeftHand",
			"RightShoulder", "RightUpperArm", "RightLowerArm", "RightHand",
			"LeftFoot", "RightFoot"]:
		_bones[name] = _skel.find_bone(StringName(name))
	if WALK:
		Input.action_press(&"move_forward")

func _process(_d: float) -> void:
	if _skel == null: return
	if WALK:
		Input.action_press(&"move_forward")
	_f += 1
	if _f < 60: return
	# Every 10th frame, so a periodic problem is still caught.
	if _f % 10 == 0:
		_samples.append(_read())
	if _samples.size() >= int(SECONDS * 6.0):
		_report()

func _read() -> Dictionary:
	var out: Dictionary = {}
	var model_up: Vector3 = _skel.global_transform.basis.y.normalized()
	for key: String in _bones:
		var idx: int = int(_bones[key])
		if idx < 0: continue
		var g: Basis = (_skel.global_transform.basis
			* _skel.get_bone_global_pose(idx).basis).orthonormalized()
		var up: Vector3 = g.y.normalized()
		var fwd: Vector3 = _model_forward()
		var side: Vector3 = model_up.cross(fwd)
		out[key] = {
			"pitch": rad_to_deg(atan2(up.dot(side.normalized()), up.dot(model_up))),
			"pos": (_skel.global_transform * _skel.get_bone_global_pose(idx)).origin,
		}
	return out

func _model_forward() -> Vector3:
	var f: Vector3 = _skel.global_transform.basis.z.normalized()
	if _skel.global_transform.basis.determinant() < 0.0:
		f = -f
	return f

func _report() -> void:
	if not WALK:
		Input.action_release(&"move_forward")
	print("[fig] %s, %d samples over %.0f frames" % [
		"WALKING" if WALK else "STANDING", _samples.size(), _f
	])
	# Per-joint pitch: the first one that departs from vertical introduces the
	# lean, and everything above it inherits.
	print("[fig] --- joint pitch vs model up (deg), worst / mean ---")
	for key: String in _bones:
		if int(_bones[key]) < 0: continue
		var worst := 0.0
		var total := 0.0
		for s: Dictionary in _samples:
			var v: float = float((s[key] as Dictionary)["pitch"])
			worst = maxf(worst, absf(v))
			total += v
		print("[fig]   %-16s worst %+6.2f  mean %+6.2f" % [
			key, signf(worst) * worst, total / float(_samples.size())
		])
	# The geometric read: head height relative to the hips, and how far the
	# hands sit behind the hips. A torso pitched forward lowers the head and
	# trails the hands even with every joint angle looking modest.
	var last: Dictionary = _samples[_samples.size() - 1]
	if last.has("Head") and last.has("Hips"):
		var head: Vector3 = (last["Head"] as Dictionary)["pos"]
		var hips: Vector3 = (last["Hips"] as Dictionary)["pos"]
		var delta := head - hips
		print("[fig] head-relative-to-hips: up %.3f m, forward %.3f m, len %.3f m" % [
			delta.y, delta.dot(_model_forward()), delta.length()
		])
	for side: String in ["Left", "Right"]:
		var hand: String = side + "Hand"
		if not last.has(hand): continue
		var hp: Vector3 = (last[hand] as Dictionary)["pos"]
		var hq: Vector3 = (last["Hips"] as Dictionary)["pos"]
		var d := hp - hq
		print("[fig] %s hand-relative-to-hips: up %+.3f m, forward %+.3f m" % [
			side, d.y, d.dot(_model_forward())
		])
	get_tree().quit(0)
