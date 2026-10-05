extends Node
class_name FootIkProbe
## A camera parked at knee height beside the sprinting player, photographing the
## same moment twice: once with the foot IK disabled and once with it running.
##
## The numbers from `walk_probe` said the solve was not landing the foot but not
## *why* — a residual error of 10-30 cm is equally consistent with a wrong axis,
## a wrong parent frame, or a chain length that does not match the rig. This
## probe answers it with pictures instead of numbers: the same sprint, the same
## camera, the same instant, one frame apart in the toggle.
##
## It also prints the three quantities that separate those theories: where the
## ankle ended up, where the solve asked for it, and the difference.

const SHOT_TIMES: Array[float] = [2.5, 3.4, 5.0, 6.4]
const RUN_TIME: float = 8.0
## Ignore the boot frames: the first seconds run at a few frames per second
## while shaders compile, and their huge deltas swamp any jitter measurement.
const MEASURE_FROM: float = 2.0

## `FOOT_IK_SPRINT=0` walks instead — the IK's design condition (the walk clip
## keeps the hips near the rest height, so the pins stay reachable; the sprint
## clip raises them past what the pelvis drop can absorb). Sprint stays the
## default so the historical runs stay comparable.
var _sprint: bool = OS.get_environment("FOOT_IK_SPRINT") != "0"

var _player: Node3D = null
var _foot_ik: ModelFootIK = null
var _cam: Camera3D = null
var _elapsed: float = 0.0
var _shots: int = 0
var _running: bool = false
## True when this probe created the component (and so may remove it on exit).
var _owned: bool = false
## Planted-phase drift: how far a foot the IK fully owns travels per frame. This
## is the acceptance number for the whole feature.
var _last_ankle: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _plant_frames: int = 0
var _plant_sum: float = 0.0
var _plant_max: float = 0.0
## Pelvis-offset jitter: the reported symptom was legs snapping forward and
## jerking a few seconds in, which is this number spiking.
var _last_pelvis: Vector3 = Vector3.ZERO
var _pelvis_step_max: float = 0.0
## How often the plant flag flips. A foot that re-plants every few frames resets
## its pin to wherever it currently is — which is no pin at all, and is the
## leading suspect for the drift that survives an otherwise correct solve.
var _switches: Array[int] = [0, 0]
var _last_planted: Array[bool] = [false, false]
## Drift sampled only when the correction is at (nearly) full strength, to tell
## "not enough correction applied" apart from "correction does not work".
var _drift_full: Array[float] = [0.0, 0.0]
var _full_frames: Array[int] = [0, 0]
## Whether the IK's `_process` is currently enabled — the shot list toggles it.
## "Full weight" must not silently mix corrected frames with clip-slide frames:
## while the IK is off its weight stays wherever it had faded to, so the old
## single aggregate read partly like an IK failure that was measurement.
var _ik_active: bool = false
## Per side, per regime (index = side * 3 + bucket): 0 = IK off (the clip's
## own slide), 1 = IK on and the foot was planted at both samples (the solve
## holding one pin — the acceptance bucket), 2 = IK on but a plant edge fell
## between the samples (a re-plant may relocate the pin; not solve error).
## x = drift sum, y = frames, z = worst frame.
var _drift_split: Array[Vector3] = [
	Vector3.ZERO, Vector3.ZERO, Vector3.ZERO,
	Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
## Time-normalized accumulators over the same buckets: x = drift sum (m),
## y = time in the bucket (s), z = weight sum. Drift per *second* is the honest
## number: the per-frame figures scale with the frame rate, and a stuttering
## sprint samples a stride apart — the old 0.18 m/frame headline was partly
## that aliasing, reading one gait cycle between consecutive probe frames.
var _drift_time: Array[Vector3] = [
	Vector3.ZERO, Vector3.ZERO, Vector3.ZERO,
	Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
## Same-frame solve quality at near-full weight, per side: x = ik_error sum,
## y = frames. Split by whether the goal was inside the chain's reach — a
## clamped-out goal is a pelvis-drop policy question (the shortfall the drop
## is capped at 0.12 m against), not solve error.
var _ikerr_in_reach: Array[Vector2] = [Vector2.ZERO, Vector2.ZERO]
var _ikerr_clamped: Array[Vector2] = [Vector2.ZERO, Vector2.ZERO]
## Body travel over the measured window, so drift can be reported as a
## fraction of the speed that matters instead of an absolute frame figure.
var _body_sum: float = 0.0
var _body_time: float = 0.0
## Per side: the pin and weight at the previous sample. A step only counts as
## held drift when the interval spanned **one pin at full strength on both
## ends** — endpoint-planted pairs that straddle a re-plant move by the
## stride, not by the solve, and read as drift without this check (the sprint
## probe measured "held" steps of 0.14 m this way while ik_error sat at
## 0.015: the pin itself had been re-planted between the samples).
var _last_pin: Array[Vector3] = [
	Vector3(1e9, 1e9, 1e9), Vector3(1e9, 1e9, 1e9)]
var _last_weight: Array[float] = [0.0, 0.0]


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Sample **after** the component ticked, not before: tree order runs this
	# probe (the boot's ancestor) first, which reads the pose left by the
	# physics tick — the body has moved one tick's worth but the IK has not
	# re-solved yet, so every sample read a 0.14 m sawtooth (one physics tick
	# at sprint speed) that the rendered frame never shows. A priority below
	# every default-0 node puts this probe last in the frame, matching what
	# the player actually sees.
	process_priority = 100.0
	# The boot is not an autoload — a probe has to instantiate it itself, the
	# way `walk_probe` does. Without this the world never exists and the window
	# stays grey.
	var packed: PackedScene = load("res://src/boot/startup.tscn") as PackedScene
	add_child(packed.instantiate())
	Events.world_ready.connect(_on_world_ready)


func _on_world_ready(_world: Node3D) -> void:
	for node: Node in get_tree().get_nodes_in_group(&"player"):
		_player = node as Node3D
		break
	if _player == null:
		print("[foot-ik-probe] no player found")
		get_tree().quit(1)
		return
	var model: Node3D = _player.get_node_or_null("PlayerModel") as Node3D
	if model == null:
		for node: Node in _player.find_children("*", "Node3D", true, false):
			var candidate := node as Node3D
			if candidate.find_child("Skeleton3D", true, false) != null:
				model = candidate
				break
	if model == null:
		print("[foot-ik-probe] no model with a skeleton")
		get_tree().quit(1)
		return
	# Reuse the attached component when the game has one; build it only if not,
	# so this probe measures the shipping behaviour either way.
	_foot_ik = model.find_child("FootIK", true, false) as ModelFootIK
	if _foot_ik == null:
		_foot_ik = ModelFootIK.new()
		_foot_ik.name = "FootIK"
		model.add_child(_foot_ik)
		_foot_ik.setup(model)
		_owned = true
	_foot_ik.set_process(false)
	# The rotation fix is on by default; FOOT_IK_FIX=0 forces it off for the
	# ON/OFF comparison run, without touching the source default.
	if OS.get_environment("FOOT_IK_FIX") == "0":
		_foot_ik.rig_rotation_fix = false
		print("[foot-ik-probe] rig_rotation_fix forced OFF by FOOT_IK_FIX=0")
	_cam = Camera3D.new()
	add_child(_cam)
	_cam.make_current()
	_cam.fov = 50.0
	print("[foot-ik-probe] ready")


func _process(delta: float) -> void:
	if _player == null:
		return
	_elapsed += delta
	_frame_camera()
	_sample_drift()
	if _elapsed > 1.0 and not _running:
		_running = true
		Input.action_press(&"move_forward")
		if _sprint:
			Input.action_press(&"sprint")
		print("[foot-ik-probe] mode: %s (FOOT_IK_SPRINT=%s)" % [
			"sprint" if _sprint else "walk", OS.get_environment("FOOT_IK_SPRINT")])
	# Alternate the IK across the shot list so each state gets both gait phases,
	# and hide the UI so the legs are the only thing in frame.
	if _shots < SHOT_TIMES.size() and _elapsed >= SHOT_TIMES[_shots]:
		var ik_on: bool = _shots % 2 == 1
		_foot_ik.set_process(ik_on)
		_ik_active = ik_on
		_hide_ui()
		_shoot("foot_%s_%d" % ["on" if ik_on else "off", _shots])
		_log("ON" if ik_on else "OFF")
		print("[foot-ik-probe] shot=%d ik=%s planted=%s w=%.2f err=%.3f" % [
			_shots, ik_on, _foot_ik.is_planted(0), _foot_ik.foot_weight(0),
			_foot_ik.ik_error(0)])
		var angles: Vector2 = _foot_ik.last_angles(0)
		print("[foot-ik-probe]   angles thigh=%.3f shin=%.3f goal=%s ankle=%s" % [
			angles.x, angles.y, _foot_ik.last_goal(0), _foot_ik.foot_world_pos(0)])
		var chain: Vector3 = _foot_ik.last_reach(0)
		print("[foot-ik-probe]   chain thigh=%.3f shin=%.3f goal=%.3f (sum=%.3f)" % [
			chain.x, chain.y, chain.z, chain.x + chain.y])
		_shots += 1
	if _elapsed >= RUN_TIME:
		Input.action_release(&"move_forward")
		Input.action_release(&"sprint")
		print("[foot-ik-probe] planted drift: frames=%d mean=%.4fm max=%.4fm" % [
			_plant_frames, _plant_sum / float(maxi(_plant_frames, 1)), _plant_max])
		print("[foot-ik-probe] pelvis jitter: max step=%.4fm offset=%s" % [
			_pelvis_step_max, _foot_ik.pelvis_offset()])
		print("[foot-ik-probe] plant switches: L=%d R=%d" % [_switches[0], _switches[1]])
		print("[foot-ik-probe] drift at full weight: L=%.4fm (%d frames) R=%.4fm (%d frames)" % [
			_drift_full[0] / float(maxi(_full_frames[0], 1)), _full_frames[0],
			_drift_full[1] / float(maxi(_full_frames[1], 1)), _full_frames[1]])
		for side: int in 2:
			var labels: Array[String] = ["off", "on+held  ", "on+replant"]
			for bucket: int in 3:
				var acc: Vector3 = _drift_split[side * 3 + bucket]
				if acc.y > 0.0:
					print("[foot-ik-probe] drift split side=%d %s frames=%d mean=%.4fm max=%.4fm" % [
						side, labels[bucket], int(acc.y), acc.x / acc.y, acc.z])
		var body_speed: float = _body_sum / maxf(_body_time, 0.0001)
		print("[foot-ik-probe] body speed mean: %.2f m/s over %.1fs" % [
			body_speed, _body_time])
		for side: int in 2:
			var labels: Array[String] = ["off", "on+held  ", "on+replant"]
			for bucket: int in 3:
				var tacc: Vector3 = _drift_time[side * 3 + bucket]
				if tacc.y > 0.0:
					var velocity: float = tacc.x / tacc.y
					print("[foot-ik-probe] drift rate side=%d %s %.2f m/s (%.0f%% of body, mean w=%.2f, %.2fs)" % [
						side, labels[bucket], velocity,
						100.0 * velocity / maxf(body_speed, 0.0001),
						tacc.z / maxf(_drift_split[side * 3 + bucket].y, 1.0),
						tacc.y])
		for side: int in 2:
			if _ikerr_in_reach[side].y > 0.0:
				print("[foot-ik-probe] solve quality side=%d in-reach: mean ik_err=%.4fm (%d frames)" % [
					side, _ikerr_in_reach[side].x / _ikerr_in_reach[side].y,
					int(_ikerr_in_reach[side].y)])
			if _ikerr_clamped[side].y > 0.0:
				print("[foot-ik-probe] solve quality side=%d clamped-out: mean shortfall=%.4fm (%d frames)" % [
					side, _ikerr_clamped[side].x / _ikerr_clamped[side].y,
					int(_ikerr_clamped[side].y)])
		get_tree().quit(0)


## Park the camera beside the legs, looking slightly down the shin — close
## enough that a foot two centimetres off its pin is obvious in the picture.
func _frame_camera() -> void:
	var basis_yaw := _player.global_transform.basis
	var side: Vector3 = basis_yaw.x.normalized()
	var forward: Vector3 = -basis_yaw.z.normalized()
	var hip: Vector3 = _player.global_position + Vector3.UP * 0.55
	_cam.global_position = hip + side * 1.05 + forward * 0.75
	_cam.look_at(hip, Vector3.UP)


## The tour's start card sits exactly where the legs are; every CanvasLayer
## goes away so the frame is world and figure only. They hang off the root,
## not off the viewport's children — the earlier version only found some of them.
func _hide_ui() -> void:
	for child: Node in get_tree().root.get_children():
		if child is CanvasLayer:
			(child as CanvasLayer).visible = false


## Sample how far a fully-owned foot moves per frame. Anything above a
## millimetre or two is the slide this component exists to remove.
func _sample_drift() -> void:
	if _foot_ik == null:
		return
	if _elapsed > MEASURE_FROM:
		_pelvis_step_max = maxf(_pelvis_step_max,
			_foot_ik.pelvis_offset().distance_to(_last_pelvis))
		var body := _player as CharacterBody3D
		if body != null:
			_body_sum += body.velocity.length() * get_process_delta_time()
			_body_time += get_process_delta_time()
	_last_pelvis = _foot_ik.pelvis_offset()
	for side: int in 2:
		var pos: Vector3 = _foot_ik.foot_world_pos(side)
		var planted: bool = _foot_ik.is_planted(side)
		var weight: float = _foot_ik.foot_weight(side)
		var was_planted: bool = _last_planted[side]
		if planted != was_planted:
			_switches[side] += 1
			_last_planted[side] = planted
		var pin_held: bool = planted and was_planted \
			and _foot_ik._plant_pos[side] == _last_pin[side]
		var full: bool = weight > 0.9 and _last_weight[side] > 0.9
		if full and _elapsed > MEASURE_FROM:
			var step: float = pos.distance_to(_last_ankle[side])
			_plant_frames += 1
			_plant_sum += step
			_plant_max = maxf(_plant_max, step)
			var bucket: int = 0 if not _ik_active else (1 if pin_held else 2)
			var index: int = side * 3 + bucket
			var acc: Vector3 = _drift_split[index]
			acc.x += step
			acc.y += 1.0
			acc.z = maxf(acc.z, step)
			_drift_split[index] = acc
			var tacc: Vector3 = _drift_time[index]
			tacc.x += step
			tacc.y += get_process_delta_time()
			tacc.z += weight
			_drift_time[index] = tacc
			if weight > 0.95:
				_full_frames[side] += 1
				_drift_full[side] += step
				# Same-frame solve quality, split by reachability: the solve
				# lands the ankle on the *clamped* goal, so a clamped frame's
				# ik_error measures the pelvis-drop cap, not the solve.
				var reach_gap: float = _foot_ik.last_goal(side).distance_to(
					_foot_ik._plant_pos[side])
				var clamped: bool = reach_gap > 0.01
				var stat: Vector2 = _ikerr_clamped[side] if clamped \
					else _ikerr_in_reach[side]
				stat += Vector2(_foot_ik.ik_error(side), 1.0)
				if clamped:
					_ikerr_clamped[side] = stat
				else:
					_ikerr_in_reach[side] = stat
			# Every full-weight step above noise gets context: was the foot
			# held on one pin, was the goal clamped out of the chain's reach
			# (the ankle then rides the hip and drifts at body speed), how far
			# the clamped goal fell short of the pin, and the frame time — a
			# stuttering frame spans a stride and reads as a huge step.
			if step > 0.02:
				var reach: Vector3 = _foot_ik.last_reach(side)
				var goal_gap: float = _foot_ik.last_goal(side).distance_to(
					_foot_ik._plant_pos[side])
				print("[foot-ik-probe]   step side=%d %.3fm dt=%.3fs w=%.2f held=%s clear=%.3f ik_err=%.3f d=%.3f reach=%.3f goal_gap=%.3f" % [
					side, step, get_process_delta_time(), weight,
					planted and was_planted,
					_foot_ik.last_clearance(side), _foot_ik.ik_error(side),
					reach.z, reach.x + reach.y, goal_gap])
				print("[foot-ik-probe]     geo ankle=%s pin=%s player=%s" % [
					pos, _foot_ik._plant_pos[side], _player.global_position])
				_diag_hips()
		_last_pin[side] = _foot_ik._plant_pos[side]
		_last_weight[side] = weight
		_last_ankle[side] = pos


## Dump the hips-bone pose triple (as found / as the IK left it / as it is
## now) plus the node bases the pelvis math conjugates through. This is the
## ground truth for whether the drop lands, accumulates or inverts.
func _diag_hips() -> void:
	var skel: Skeleton3D = _foot_ik._skeleton
	if skel == null:
		return
	var hips: int = skel.find_bone("Hips")
	if hips < 0:
		print("[foot-ik-probe]   diag: no Hips bone")
		return
	var st := skel.global_transform
	print("[foot-ik-probe]   diag hips now=%s base=%s written=%s" % [
		skel.get_bone_pose(hips).origin,
		_foot_ik._hips_base, _foot_ik._hips_written])
	print("[foot-ik-probe]   diag skel scale=%s y=%s | model y=%s parent_bone=%d" % [
		st.basis.get_scale(), st.basis.y,
		(_foot_ik._model as Node3D).global_transform.basis.y,
		skel.get_bone_parent(hips)])


func _shoot(name: String) -> void:
	var image := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute("data/screenshots")
	image.save_png("data/screenshots/%s.png" % name)


## Print the three quantities that tell the theories apart.
func _log(label: String) -> void:
	if _foot_ik == null:
		return
	for side: int in 2:
		var chain: Dictionary = {}
		for node: Node in _player.find_children("*", "Skeleton3D", true, false):
			var skel := node as Skeleton3D
			var foot: int = skel.find_bone("LeftFoot" if side == 0 else "RightFoot")
			if foot >= 0:
				chain = {
					"ankle": (skel.global_transform * skel.get_bone_global_pose(foot)).origin,
					"ground": skel.get_bone_global_pose(foot).origin.y,
				}
				break
		if chain.is_empty():
			continue
		print("[foot-ik-probe] %s side=%d ankle=(%.3f, %.3f, %.3f) clearance=%.3f" % [
			label, side,
			(chain["ankle"] as Vector3).x, (chain["ankle"] as Vector3).y,
			(chain["ankle"] as Vector3).z, _foot_ik.last_clearance(side)])
