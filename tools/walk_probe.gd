extends Node
## Walk-analysis probe running the REAL boot sequence: full startup (real map,
## real camera, real physics), then simulated sprint input with per-frame
## readings of body velocity, model-vs-body offset and pose deltas — on grass
## and through the pond, land and water in one run.

var _player: Player
var _clips: ModelClips
var _skel: Skeleton3D
var _bone: int = -1
var _prev_rot: Quaternion
var _frames: int = 0
var _armed: bool = false
var _prev_pos: Vector3 = Vector3.ZERO
var _prev_render: Vector3 = Vector3.ZERO


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
	print("[walk-probe] model=%s bones=%d" % [
		model.scene_file_path, _skel.get_bone_count()])
	# Close framing on the legs: the default 5.4 m orbit cannot show whether
	# the stride itself is sane.
	if _player.camera_rig != null:
		_player.camera_rig.arm_length = 1.9
		_player.camera_rig.pivot_height = 0.75
		_player.camera_rig._apply_arm(1.9)
	Input.action_press(&"move_forward")
	Input.action_press(&"sprint")
	_armed = true


func _process(_delta: float) -> void:
	if not _armed:
		return
	_frames += 1
	var model := _player.get_node_or_null("PlayerModel") as Node3D
	var model_offset: Vector3 = model.global_position - _player.global_position
	var delta_pos: float = (_player.global_position - _prev_pos).length()
	_prev_pos = _player.global_position
	var rot := _skel.get_bone_pose_rotation(_bone)
	var pose_step: float = rot.angle_to(_prev_rot)
	_prev_rot = rot
	var rig_dist: float = -1.0
	if _player.camera_rig != null:
		rig_dist = _player.camera_rig.global_position.distance_to(
			_player.global_position)
	# The interpolated (rendered) position, next to the physics one: with
	# physics interpolation on, this advances every rendered frame while the
	# physics position steps at 60 Hz — that is exactly the judder fix.
	var render_pos: Vector3 = _player.get_global_transform_interpolated().origin
	var render_delta: float = (render_pos - _prev_render).length()
	_prev_render = render_pos
	# Per-frame for the first 120 frames: the stutter, if some frames move
	# twice as far as others (physics catch-up / missing interpolation), is
	# a frame-level signature and coarse sampling would hide it.
	if _frames <= 120:
		print("[walk-probe] f%03d dpos=%.4f drend=%.4f pv=%.2f rig=%.3f moff=%.4f step=%.4f" % [
			_frames, delta_pos, render_delta, _player.velocity.length(),
			rig_dist, model_offset.length(), pose_step])
	elif _frames % 12 == 0:
		print("[walk-probe] f%03d dpos=%.4f drend=%.4f pv=%.2f rig=%.3f moff=%.4f" % [
			_frames, delta_pos, render_delta, _player.velocity.length(),
			rig_dist, model_offset.length()])
	# A visual strip: one frame per gait phase, to be read as a film strip.
	if _frames % 30 == 0:
		var img := get_viewport().get_texture().get_image()
		DirAccess.make_dir_recursive_absolute("data/screenshots/walk_seq")
		img.save_png("data/screenshots/walk_seq/frame_%d.png" % _frames)
	if _frames > 240:
		Input.action_release(&"move_forward")
		Input.action_release(&"sprint")
		get_tree().quit(0)
