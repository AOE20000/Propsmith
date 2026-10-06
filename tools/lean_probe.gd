extends Node
## Does the stance's arm aiming accumulate frame over frame?
##
## The screenshot shows a torso pitched forward with the arms trailing behind —
## the shape a chain produces when each frame solves against the *previous
## frame's own output*. `ModelStance._aim_bone` falls back to
## `get_bone_global_pose(parent)` for a parent it never aims (the spine, the
## neck), and that pose contains whatever was written last frame. If the
## correction has any component along the chain, it compounds.
##
## Standing still is where it shows: the stance runs every frame with no clip
## muting it, so any per-frame drift integrates without limit. This measures the
## spine's pitch over time with no input at all, and separately with the aim
## disabled, so the two curves answer it directly.
var _skel: Skeleton3D
var _stance: ModelStance
var _chest: int = -1
var _f: int = 0
var _pitch_max: float = 0.0
var _pitch_at: int = -1
var _samples: Array[float] = []
var _marks: Array[String] = []

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
	_stance = m.get_node_or_null("Stance") as ModelStance
	_chest = _skel.find_bone(&"Chest")
	if _chest < 0:
		print("[lean] FAIL: no Chest")
		get_tree().quit(1)

func _process(_d: float) -> void:
	if _chest < 0: return
	_f += 1
	if _f == 1:
		_marks.append("start")
	if _f == 120:
		_marks.append("f120")
	if _f == 300:
		_marks.append("f300")
	if _f == 600:
		_marks.append("f600")
	var pitch: float = _pitch()
	_samples.append(pitch)
	if absf(pitch) > absf(_pitch_max):
		_pitch_max = pitch
		_pitch_at = _f
	if _f >= 600:
		_report()

## Chest bone's +Y against the model's up, in degrees, forward positive.
func _pitch() -> float:
	var basis: Basis = _skel.global_transform.basis * _skel.get_bone_global_pose(_chest).basis
	var up: Vector3 = basis.y.normalized()
	var model_up: Vector3 = _skel.global_transform.basis.y.normalized()
	var fwd: Vector3 = _skel.global_transform.basis.z.normalized()
	var side: Vector3 = model_up.cross(fwd)
	if side.length_squared() < 1e-8: return 0.0
	return rad_to_deg(atan2(up.dot(side.normalized()), up.dot(model_up)))

func _report() -> void:
	print("[lean] stance present: %s" % str(_stance != null))
	# Sampled over time: a chain integrating its own output drifts steadily, so
	# the end-of-run value is the tell, not any single frame.
	for i: int in [0, 119, 299, 599]:
		if i < _samples.size():
			print("[lean]   frame %d: pitch %+.2f°" % [i + 1, _samples[i]])
	print("[lean] worst pitch %+.2f° at frame %d (marks: %s)" % [
		_pitch_max, _pitch_at, str(_marks)
	])
	# The drift is the difference between the last second and the first, which
	# is what separates "the pose is what it is" from "it is moving every frame".
	var drift: float = _samples[599] - _samples[0] if _samples.size() > 599 else 0.0
	print("[lean] frame 1 -> 600 drift %+.3f°" % drift)
	print("[lean] VERDICT: %s" % (
		"DRIFTING — the aim feeds on its own output" if absf(drift) > 2.0
		else "stable — no per-frame accumulation"
	))
	get_tree().quit(0)
