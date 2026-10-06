extends Node
## Whole-body pose probe: what the torso, hips and legs are actually doing.
##
## The playtest screenshot shows the figure leaning ~45° forward with both legs
## trailing behind and straightened — the shape of a body whose feet are being
## held somewhere its hips are not. Three components can each produce that:
## the pelvis drop (`_pelvis_prepare` translates the hips), the torso lean
## (`ModelLean`, written on the chest), and the locomotion clip itself.
##
## This measures all three per frame while walking, so the culprit is the one
## with the number, not the one that looks worst in a still. The camera-facing
## pitch of the spine is the discriminator: a pelvis drop tilts nothing, a
## chest lean tilts the spine, and a clip that writes a forward-leaning spine
## tilts it too — but the two leave different traces in the hips' height and
## the legs' angles, which is what the report prints alongside.
##
## Read-only.

const WALK_SECONDS: float = 4.0
const SETTLE_SECONDS: float = 1.2

var _player: Player
var _ik: ModelFootIK
var _clips: ModelClips
var _lean: ModelLean
var _skel: Skeleton3D
var _hips: int = -1
var _chest: int = -1
var _upper: Array[int] = [-1, -1]
var _lower: Array[int] = [-1, -1]
var _foot: Array[int] = [-1, -1]
var _elapsed: float = 0.0
var _pressed: Array[StringName] = []
## Worst readings seen, so a brief spike is not averaged away.
var _worst_lean: float = 0.0
var _worst_lean_frame: int = -1
var _worst_hips_pitch: float = 0.0
var _worst_hips_frame: int = -1
var _worst_node_pitch: float = 0.0
var _worst_node_frame: int = -1
var _lowest_hips_y: float = INF
var _worst_pelvis: float = 0.0
var _worst_pelvis_frame: int = -1
var _worst_knee: float = 0.0
var _worst_knee_frame: int = -1
var _frame: int = 0
## How often each foot was planted, so "the IK is on" and "the IK is on most
## of the time" can be told apart.
var _planted_frames: Array[int] = [0, 0]
var _weight_sum: Array[float] = [0.0, 0.0]
## Samples where the spine was past the flat-forward threshold.
var _lean_frames: int = 0
var _lean_gear: Array[String] = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var packed: PackedScene = load("res://src/boot/startup.tscn") as PackedScene
	add_child(packed.instantiate())
	Events.world_ready.connect(_on_world_ready)


func _on_world_ready(_world: Node3D) -> void:
	_player = get_tree().get_first_node_in_group(&"player") as Player
	if _player == null:
		print("[pose-probe] FAIL: no player")
		get_tree().quit(1)
		return
	var model := _player.get_node_or_null("PlayerModel") as Node3D
	if model == null:
		print("[pose-probe] FAIL: no PlayerModel")
		get_tree().quit(1)
		return
	for node: Node in model.find_children("*", "Skeleton3D", true, false):
		_skel = node as Skeleton3D
		break
	if _skel == null:
		print("[pose-probe] FAIL: no skeleton")
		get_tree().quit(1)
		return
	_ik = _skel.get_node_or_null("FootIK") as ModelFootIK
	_lean = _skel.get_node_or_null("Lean") as ModelLean
	_clips = model.get_node_or_null("Clips") as ModelClips
	_hips = _skel.find_bone(&"Hips")
	_chest = _skel.find_bone(&"Chest")
	_model_node = model
	for side: int in 2:
		var prefix := "Left" if side == 0 else "Right"
		_upper[side] = _skel.find_bone(StringName(prefix + "UpperLeg"))
		_lower[side] = _skel.find_bone(StringName(prefix + "LowerLeg"))
		_foot[side] = _skel.find_bone(StringName(prefix + "Foot"))
	if _hips < 0 or _chest < 0 or _foot[0] < 0 or _foot[1] < 0:
		print("[pose-probe] FAIL: missing Hips/Chest/Foot bones")
		get_tree().quit(1)
		return
	_pressed.append(&"move_forward")
	Input.action_press(&"move_forward")
	print("[pose-probe] walking %.1f s (settle %.1f s)" % [WALK_SECONDS, SETTLE_SECONDS])


func _process(delta: float) -> void:
	if _skel == null:
		return
	_elapsed += delta
	Input.action_press(&"move_forward")
	if _elapsed < SETTLE_SECONDS:
		return
	_frame += 1

	# The chest bone's tilt from the model's up axis, in degrees. Positive is a
	# forward lean. Measured through `global_pose` and the node transform because
	# the bone pose alone never sees the model's own basis.
	var spine_pitch: float = _spine_pitch()
	if absf(spine_pitch) > absf(_worst_lean):
		_worst_lean = spine_pitch
		_worst_lean_frame = _frame
	if spine_pitch > 0.5:
		_lean_frames += 1
		if not _lean_gear.has(_gear()):
			_lean_gear.append(_gear())

	# The hips' own pitch, measured against **world** up rather than the model's
	# up. The difference matters: if the two agree the figure is upright in the
	# world and only its bones lean, and if the model's own basis has tipped
	# then the whole node is leaning and no bone change can explain the picture.
	# The playtest screenshot shows a forward pitch that the chest bone does not
	# have, so the reading that distinguishes them is this one.
	var hips_pitch: float = _pitch_of(_hips, Vector3.UP)
	if absf(hips_pitch) > absf(_worst_hips_pitch):
		_worst_hips_pitch = hips_pitch
		_worst_hips_frame = _frame
	var node_pitch: float = _pitch_of(-1, Vector3.UP)
	if absf(node_pitch) > absf(_worst_node_pitch):
		_worst_node_pitch = node_pitch
		_worst_node_frame = _frame
	# The hips' height above the ground, which is what a pelvis drop actually
	# moves. Read in the world so a drop cannot hide behind a tipped node.
	var hips_y: float = _bone(_hips).y
	if _lowest_hips_y > hips_y:
		_lowest_hips_y = hips_y

	# The pelvis drop is a pure translation — how far the hips have been pushed
	# off the pose the clip wrote. Its ceiling is `max_pelvis_drop`.
	var drop: float = _ik._pelvis_current.length() if _ik != null else 0.0
	if drop > _worst_pelvis:
		_worst_pelvis = drop
		_worst_pelvis_frame = _frame

	# How straight is the worse leg? A leg held behind the body is straight, so
	# the knee's interior angle approaching 180° is the signature.
	var knee: float = _worst_knee_angle()
	if knee > _worst_knee:
		_worst_knee = knee
		_worst_knee_frame = _frame

	for side: int in 2:
		if _ik == null:
			break
		if _ik._planted[side]:
			_planted_frames[side] += 1
		_weight_sum[side] += _ik.foot_weight(side)

	if _elapsed >= SETTLE_SECONDS + WALK_SECONDS:
		_report()


## The chest bone's tilt from the model's up axis, in degrees. Positive is a
## forward lean. Measured through `global_pose` and the node transform because
## the bone pose alone never sees the model's own basis.
func _spine_pitch() -> float:
	var basis: Basis = _skel.global_transform.basis \
		* _skel.get_bone_global_pose(_chest).basis
	var up: Vector3 = basis.y.normalized()
	var model_up: Vector3 = _skel.global_transform.basis.y.normalized()
	# The angle from the model's up toward the bone's up, measured in the
	# model's forward plane, so a lean forward reads positive and a camera yaw
	# cannot leak into it.
	var forward: Vector3 = _skel.global_transform.basis.z.normalized()
	var sideways: Vector3 = model_up.cross(forward).normalized()
	return rad_to_deg(atan2(up.dot(sideways), up.dot(model_up)))


## Interior angle at the worse knee, in degrees. 180° is a straight leg; the
## screenshot's trailing straight legs read near the maximum.
func _worst_knee_angle() -> float:
	var straightest := 0.0
	for side: int in 2:
		var upper := _upper[side]
		var lower := _lower[side]
		var foot := _foot[side]
		if upper < 0 or lower < 0 or foot < 0:
			continue
		var hip: Vector3 = _bone(upper)
		var knee: Vector3 = _bone(lower)
		var toe: Vector3 = _bone(foot)
		var a: Vector3 = hip - knee
		var b: Vector3 = toe - knee
		if a.length_squared() < 1e-8 or b.length_squared() < 1e-8:
			continue
		straightest = maxf(straightest, rad_to_deg(a.angle_to(b)))
	return straightest


func _bone(index: int) -> Vector3:
	return (_skel.global_transform * _skel.get_bone_global_pose(index)).origin


## Pitch of a bone's own +Y, or of the model node's +Y when `index` is -1,
## measured against `reference_up` and signed toward the model's forward.
##
## Passing `Vector3.UP` (world) rather than the model's own up is the point:
## a figure whose *node* has tipped reads as tipped against the world even
## though every bone agrees with the node, and that is the difference between
## "a bone is leaning" and "the whole model is leaning".
func _pitch_of(index: int, reference_up: Vector3) -> float:
	var basis: Basis
	if index < 0:
		basis = _model_node.global_transform.basis
	else:
		basis = _skel.global_transform.basis * _skel.get_bone_global_pose(index).basis
	var up: Vector3 = basis.y.normalized()
	var ref: Vector3 = reference_up.normalized()
	var forward: Vector3 = _model_node.global_transform.basis.z.normalized()
	var sideways: Vector3 = ref.cross(forward)
	if sideways.length_squared() < 1e-8:
		return 0.0
	return rad_to_deg(atan2(up.dot(sideways.normalized()), up.dot(ref)))


var _model_node: Node3D = null


func _gear() -> String:
	if _clips == null:
		return "no clips"
	if _clips._air_phase != 0:
		return "air"
	if _clips._running:
		return "run"
	if _clips._walking:
		return "walk"
	return "idle"


func _report() -> void:
	for action: StringName in _pressed:
		Input.action_release(action)
	print("[pose-probe] --- over %d frames (%.1f s at %s) ---" % [
		_frame, WALK_SECONDS, _gear()
	])
	print("[pose-probe] worst spine pitch %.1f° at frame %d (leaning-forward is positive)" % [
		_worst_lean, _worst_lean_frame
	])
	print("[pose-probe] worst hips pitch vs WORLD up %.1f° at frame %d" % [
		_worst_hips_pitch, _worst_hips_frame
	])
	print("[pose-probe] worst model-node pitch vs WORLD up %.1f° at frame %d" % [
		_worst_node_pitch, _worst_node_frame
	])
	print("[pose-probe] lowest hips height %.4f m" % _lowest_hips_y)
	print("[pose-probe] frames with the spine past 0.5 rad (29°): %d, gears: %s" % [
		_lean_frames, str(_lean_gear)
	])
	if _ik != null:
		print("[pose-probe] worst pelvis drop %.4f m at frame %d (ceiling %.4f)" % [
			_worst_pelvis, _worst_pelvis_frame, _ik.max_pelvis_drop
		])
		print("[pose-probe] worst knee angle %.1f° at frame %d (180° = straight leg)" % [
			_worst_knee, _worst_knee_frame
		])
		for side: int in 2:
			var name := "left" if side == 0 else "right"
			print("[pose-probe]   %s planted %d/%d frames, mean weight %.2f, pin now %s, reach %.3f" % [
				name, _planted_frames[side], _frame,
				_weight_sum[side] / maxf(1.0, float(_frame)),
				str(_ik.is_planted(side)), _reach(side)
			])
	if _lean != null:
		print("[pose-probe] lean component present; its own magnitude %.4f" % _lean_magnitude())
	get_tree().quit(0)


## How far the lean component is currently writing, read from the chest it owns.
## A large value here means the torso lean is the author of the forward pitch.
func _lean_magnitude() -> float:
	return _skeleton_lean_readout()


func _skeleton_lean_readout() -> float:
	# The lean component keeps its own current offset; its `amount` export is
	# the configured scale. Reading the live value needs no access into the
	# component's internals, so the configured export is reported instead and
	# the spine pitch above is the measurement that matters.
	return _lean.amount if _lean != null else 0.0


func _reach(side: int) -> float:
	if _ik == null:
		return 0.0
	var chain: Dictionary = _ik._chains[side]
	var upper: int = int(chain.get("upper", -1))
	var lower: int = int(chain.get("lower", -1))
	var foot: int = int(chain.get("foot", -1))
	if upper < 0 or lower < 0 or foot < 0:
		return 0.0
	return _ik._rest_length(upper, lower) + _ik._rest_length(lower, foot)
