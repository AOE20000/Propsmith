extends Node
## Contrast experiment: (a) inspect the VRM skeleton's freeze flags;
## (b) a minimal hand-built skeleton + hand-built animation, zero imports —
## if the minimal rig also refuses to move, the problem is environmental,
## not in the VRM scene or the attachment stack.

var _frames: int = 0
var _mini_skel: Skeleton3D
var _mini_anim: AnimationPlayer
var _mini_rot0: Quaternion
var _vrm_skel: Skeleton3D
var _vrm_anim: AnimationPlayer
var _vrm_bone: int = -1
var _vrm_rot0: Quaternion


func _ready() -> void:
	# (a) VRM: freeze flags + manual-mode walk
	var packed: PackedScene = load("res://assets/characters/base_female.vrm") as PackedScene
	var model: Node3D = packed.instantiate() as Node3D
	add_child(model)
	FigureAttachments.attach_all(model)
	_vrm_skel = model.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	_vrm_anim = model.find_children("*", "AnimationPlayer", true, false)[0] as AnimationPlayer
	print("[mini] vrm show_rest_only=%s motion_scale=%.2f bones=%d" % [
		_vrm_skel.show_rest_only, _vrm_skel.motion_scale, _vrm_skel.get_bone_count()])
	var root_bone := _vrm_skel.find_bone("Root")
	_vrm_bone = root_bone if root_bone >= 0 else 0
	_vrm_rot0 = _vrm_skel.get_bone_pose_rotation(_vrm_bone)
	_vrm_anim.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	_vrm_anim.play(&"locomotion/walk")
	_vrm_anim.advance(0.25)
	print("[mini] vrm after advance(0.25): delta=%.4f" % [
		_vrm_skel.get_bone_pose_rotation(_vrm_bone).angle_to(_vrm_rot0)])

	# (b) minimal rig: a code-built skeleton with one animated bone
	var holder := Node3D.new()
	holder.name = "MiniRig"
	add_child(holder)
	_mini_skel = Skeleton3D.new()
	holder.add_child(_mini_skel)
	var idx: int = _mini_skel.add_bone("TestBone")
	_mini_skel.set_bone_rest(idx, Transform3D(Basis(), Vector3(0, 1, 0)))
	_mini_anim = AnimationPlayer.new()
	holder.add_child(_mini_anim)
	var lib := AnimationLibrary.new()
	var anim := Animation.new()
	anim.length = 1.0
	anim.loop_mode = Animation.LOOP_LINEAR
	var track := anim.add_track(Animation.TYPE_ROTATION_3D)
	anim.track_set_path(track, NodePath("Skeleton3D:TestBone"))
	anim.track_insert_key(track, 0.0, Quaternion(Vector3.UP, 0.0))
	anim.track_insert_key(track, 0.5, Quaternion(Vector3.UP, 1.2))
	lib.add_animation(&"spin", anim)
	_mini_anim.add_animation_library(&"test", lib)
	_mini_rot0 = _mini_skel.get_bone_pose_rotation(idx)
	_mini_anim.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	_mini_anim.play(&"test/spin")
	_mini_anim.advance(0.25)
	var mini_rot := _mini_skel.get_bone_pose_rotation(idx)
	print("[mini] minimal after advance(0.25): delta=%.4f (expect ~0.6)" % mini_rot.angle_to(_mini_rot0))


func _process(_delta: float) -> void:
	_frames += 1
	if _frames == 30:
		var mini_rot := _mini_skel.get_bone_pose_rotation(0)
		print("[mini] frame30 minimal delta=%.4f" % mini_rot.angle_to(_mini_rot0))
		print("[mini] frame30 vrm delta=%.4f" % [
			_vrm_skel.get_bone_pose_rotation(_vrm_bone).angle_to(_vrm_rot0)])
		get_tree().quit(0)
