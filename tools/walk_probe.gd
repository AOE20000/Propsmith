extends Node
## Walk/run analysis probe running the REAL boot sequence, driven by *elapsed
## time* rather than frame count: a frame-counted probe ends in well under a
## second on an uncapped frame rate, before the sprint gear even engages — the
## earlier "1 second and done" run was exactly that mistake.
##
## Timeline: 0.5 s of walk, then sprint held for the rest, 6 s total (about 25
## wraps of the 0.24 s run cycle at 2.4x), logging the active gear, the pelvis
## pose's per-frame travel (a non-looping clip jumps metres at every wrap) and
## the rendered-vs-physics position deltas.

var _player: Player
var _clips: ModelClips
var _skel: Skeleton3D
var _bone: int = -1
var _prev_rot: Quaternion
var _prev_pos: Vector3 = Vector3.ZERO
var _prev_render: Vector3 = Vector3.ZERO
var _prev_hips_pos: Vector3 = Vector3.ZERO
var _elapsed: float = 0.0
var _next_log: float = 0.0
var _armed: bool = false
var _sprint_started: bool = false
var _run_frames: int = 0
var _worst_hips_jump: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var packed: PackedScene = load("res://src/boot/startup.tscn") as PackedScene
	add_child(packed.instantiate())
	Events.world_ready.connect(_on_world_ready)


func _on_world_ready(_world: Node3D) -> void:
	_player = get_tree().get_first_node_in_group(&"player") as Player
	if _player == null:
		print("[walk-probe] FAIL: no player after boot")
		get_tree().quit(1)
		return
	var model := _player.get_node_or_null("PlayerModel") as Node3D
	if model == null:
		print("[walk-probe] FAIL: no PlayerModel attached")
		get_tree().quit(1)
		return
	_clips = model.get_node_or_null("Clips") as ModelClips
	_skel = model.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	_bone = _skel.find_bone("Hips")
	if _bone < 0:
		_bone = 0
	_prev_rot = _skel.get_bone_pose_rotation(_bone)
	_prev_hips_pos = _skel.get_bone_pose_position(_bone)
	print("[walk-probe] model=%s bones=%d" % [
		model.scene_file_path, _skel.get_bone_count()])
	# Close framing on the legs, so the film strip can be judged by eye.
	if _player.camera_rig != null:
		_player.camera_rig.arm_length = 1.9
		_player.camera_rig.pivot_height = 0.75
		_player.camera_rig._apply_arm(1.9)
	Input.action_press(&"move_forward")
	_armed = true


func _process(delta: float) -> void:
	if not _armed:
		return
	_elapsed += delta
	# Sprint starts after half a second of walking, so both gears are exercised.
	if not _sprint_started and _elapsed >= 0.5:
		Input.action_press(&"sprint")
		_sprint_started = true
		print("[walk-probe] --- sprint engaged at t=%.2f ---" % _elapsed)

	var model := _player.get_node_or_null("PlayerModel") as Node3D
	var model_offset: Vector3 = model.global_position - _player.global_position
	var delta_pos: float = (_player.global_position - _prev_pos).length()
	_prev_pos = _player.global_position
	var render_pos: Vector3 = _player.get_global_transform_interpolated().origin
	var render_delta: float = (render_pos - _prev_render).length()
	_prev_render = render_pos
	var rot := _skel.get_bone_pose_rotation(_bone)
	var pose_step: float = rot.angle_to(_prev_rot)
	_prev_rot = rot
	var hips_pos: Vector3 = _skel.get_bone_pose_position(_bone)
	var hips_jump: float = (hips_pos - _prev_hips_pos).length()
	_prev_hips_pos = hips_pos
	var rig_dist: float = -1.0
	if _player.camera_rig != null:
		rig_dist = _player.camera_rig.global_position.distance_to(
			_player.global_position)
	if _clips._running:
		_run_frames += 1
		_worst_hips_jump = maxf(_worst_hips_jump, hips_jump)

	# Log every frame for the first 3 s (the gear change and the first wraps
	# are in there), then four times a second.
	if _elapsed <= 3.0 or _elapsed >= _next_log:
		if _elapsed > 3.0:
			_next_log = _elapsed + 0.25
		print("[walk-probe] t=%.2f %s dpos=%.4f drend=%.4f hijump=%.4f pv=%.2f rig=%.3f step=%.4f" % [
			_elapsed, "RUN " if _clips._running else "walk",
			delta_pos, render_delta, hips_jump, _player.velocity.length(),
			rig_dist, pose_step])
	if _elapsed >= 6.0:
		print("[walk-probe] summary: run_frames=%d worst_hijump=%.4f" % [
			_run_frames, _worst_hips_jump])
		Input.action_release(&"move_forward")
		Input.action_release(&"sprint")
		get_tree().quit(0)
