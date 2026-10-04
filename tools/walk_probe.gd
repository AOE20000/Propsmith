extends Node
## Walk-analysis probe: a real Player walks forward via a simulated input
## action, while ModelClips' internal state (measured speed, walking flag,
## clip time) and the actual pose delta are printed across frames. The gait
## stutter — if it comes from physics/render rate mismatch, threshold flips,
## or repeated clip restarts — shows up as a distinctive signature in these
## numbers instead of as a feeling.

var _player: Player
var _clips: ModelClips
var _frames: int = 0
var _prev_rot: Quaternion
var _bone: int = -1
var _skel: Skeleton3D
var _hips_track: int = -1


func _ready() -> void:
	# The probe does not run the boot sequence, so the mod load that startup
	# normally performs has to happen here — otherwise the player_model
	# registry is empty and the probe tests the fallback, not the game.
	ModHost.load_all()
	var entries: Array = ModHost.content_ordered(&"player_model")
	print("[walk-probe] player_model entries=%d exists=%s" % [
		entries.size(),
		ResourceLoader.exists("res://assets/characters/base_female.vrm", "PackedScene")])
	for entry: Dictionary in entries:
		print("[walk-probe]   entry id=%s owner=%s factory=%s" % [
			entry.get("id"), entry.get("owner"), entry.get("factory")])
	var resolved: Node3D = PlayerScene.resolve_player_model()
	print("[walk-probe] resolve -> %s" % (resolved.scene_file_path if resolved != null else "<null>"))
	if resolved != null:
		resolved.free()

	_player = PlayerScene.build()
	add_child(_player)
	# A floor, so the walk is on solid ground instead of falling while walking
	# (the fall polluted the first run's speed trace).
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = 1
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(160.0, 1.0, 160.0)
	floor_shape.shape = floor_box
	floor_body.add_child(floor_shape)
	floor_body.position = Vector3(0.0, -0.5, 0.0)
	add_child(floor_body)
	_player.global_position = Vector3(0.0, 1.0, 0.0)
	var model := _player.get_node_or_null("PlayerModel") as Node3D
	if model == null:
		print("[walk-probe] FAIL: no PlayerModel attached")
		get_tree().quit(1)
		return
	print("[walk-probe] attached model scene: %s (bones=%d)" % [
		model.scene_file_path,
		(model.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D).get_bone_count()])
	print("[walk-probe] player children:")
	for child: Node in _player.get_children():
		print("[walk-probe]   - %s (%s)" % [child.name, child.get_class()])
	_clips = model.get_node_or_null("Clips") as ModelClips
	_skel = model.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	var touched: PackedStringArray = _clips._touched_bones
	# Hips: touched[0] ("Root") does not resolve on the real-build skeleton,
	# which silently produced all-zero readings in the first run.
	_bone = _skel.find_bone("Hips")
	if _bone < 0:
		_bone = 0
	_prev_rot = _skel.get_bone_pose_rotation(_bone)
	# Find the walk clip's Hips *rotation* track, to compare the sampler's raw
	# interpolation against what actually landed on the bone.
	var walk: Animation = (_clips._library as AnimationLibrary).get_animation(&"walk")
	for track: int in walk.get_track_count():
		var path := String(walk.track_get_path(track))
		if path.contains("Hips") and walk.track_get_type(track) == Animation.TYPE_ROTATION_3D:
			_hips_track = track
			break
	print("[walk-probe] hips_bone=%d hips_track=%d walk_len=%.3f" % [
		_bone, _hips_track, walk.length])
	# Hold "move forward" and sprint for the whole run.
	Input.action_press(&"move_forward")
	Input.action_press(&"sprint")
	print("[walk-probe] bone=%s touched0=%s touched_n=%d thr=%.2f" % [
		_skel.get_bone_name(_bone),
		touched[0] if touched.size() > 0 else "<none>",
		touched.size(), _clips.walk_threshold])


func _process(_delta: float) -> void:
	_frames += 1
	var model := _player.get_node_or_null("PlayerModel") as Node3D
	var model_offset := model.global_position - _player.global_position
	var rot := _skel.get_bone_pose_rotation(_bone)
	var pose_step: float = rot.angle_to(_prev_rot)
	_prev_rot = rot
	if _frames <= 120:
		print("[walk-probe] f%03d pv=%.2f moff=%s ppos=%s step=%.4f" % [
			_frames, _player.velocity.length(),
			model_offset, _player.global_position, pose_step])
	if _frames >= 120:
		Input.action_release(&"move_forward")
		get_tree().quit(0)
