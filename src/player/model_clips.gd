extends Node
class_name ModelClips
## Locomotion clips for the shared base figure, driven by measured speed —
## the animation half of "on demand": a figure that stands still costs no
## clip evaluation, and one that walks gets a real stride instead of sliding.
##
## The clips come from `assets/animations/locomotion.res` (built by
## `tools/models/build_locomotion_library.gd` from catprisbrey's open
## ShooterLib, CC-BY 4.0): `walk`, `idle` and `run_067`, retargeted onto our
## skeleton's own node and bone names at build time, with the author rig's
## Hips-height re-anchored to ours.
##
## Division of labour with the other components, all measured:
## * While a clip plays it owns the whole pose — so `ModelStance`'s per-frame
##   breathing/sway writes are suppressed (they would otherwise overwrite the
##   clip's Spine/Neck values every frame, because the stance node sits later
##   in the tree and its writes would win).
## * When the figure slows down, the clip stops, every bone the clips touched
##   is restored to its rest pose, and the stance re-aims the arms and resumes
##   breathing — idle stays procedural, walk is authored.
##
## Playback speed tracks the measured velocity, so the stride matches the
## ground speed instead of moonwalking at a fixed cadence.

## Library path and the clip names inside it (built by the tool script).
const LIBRARY_PATH: String = "res://assets/animations/locomotion.res"
const WALK_CLIP: StringName = &"walk"
## The ground speed the walk clip was authored for (m/s). `speed_scale`
## divides the measured speed by this, so faster movement plays the cycle
## proportionally faster instead of moonwalking.
@export var clip_authored_speed: float = 1.3
## Speed above which the figure counts as walking (m/s).
@export var walk_threshold: float = 0.25
## How quickly playback speed follows measured speed (per second).
@export var speed_lerp: float = 6.0

var _model: Node3D = null
var _player: AnimationPlayer = null
var _stance: ModelStance = null
var _touched_bones: PackedStringArray = []
var _last_position: Vector3 = Vector3.ZERO
var _speed: float = 0.0
var _walking: bool = false
var _forced: StringName = &""


## Bind to a model root and wire the library into its AnimationPlayer.
## A model without the player/library simply never walks (capsule fallback).
func setup(model: Node3D) -> void:
	_model = model
	if model == null:
		return
	_player = model.find_children("*", "AnimationPlayer", true, false)[0] as AnimationPlayer \
		if model.find_children("*", "AnimationPlayer", true, false).size() > 0 else null
	if _player == null:
		return
	if not ResourceLoader.exists(LIBRARY_PATH):
		return
	var library := load(LIBRARY_PATH) as AnimationLibrary
	if library == null:
		return
	if _player.get_animation_library_list().has(&"locomotion"):
		return
	_player.add_animation_library(&"locomotion", library)
	_touched_bones = _collect_bones(library)
	_stance = model.get_node_or_null("Stance") as ModelStance
	# A model attached while its agent is still outside the tree (boot order)
	# has no meaningful world position yet — the first _process re-anchors.
	_last_position = model.global_position if model.is_inside_tree() else Vector3.ZERO


## The union of every bone the locomotion clips touch — the set that must be
## restored when the clips stop, so a figure doesn't idle in mid-stride.
func _collect_bones(library: AnimationLibrary) -> PackedStringArray:
	var bones := {}
	for clip_name: StringName in library.get_animation_list():
		var animation := library.get_animation(clip_name)
		for track: int in animation.get_track_count():
			var path := String(animation.track_get_path(track))
			var bone := path.get_slice(":", 1)
			if bone != "" and not bones.has(bone):
				bones[bone] = true
	var result := PackedStringArray()
	for bone: String in bones:
		result.append(bone)
	return result


## Pin the figure to one clip regardless of speed — the screenshot probe's
## handle, so a stride can be *photographed*.
func debug_play(clip_name: StringName) -> void:
	_forced = clip_name
	_start_clip(clip_name, 1.0)


func _process(delta: float) -> void:
	if _model == null or _player == null:
		return
	if not _model.is_inside_tree():
		return
	if not _forced.is_empty():
		return
	var displacement := _model.global_position - _last_position
	_last_position = _model.global_position
	displacement.y = 0.0
	var speed := displacement.length() / maxf(delta, 1e-4)
	_speed = lerpf(_speed, speed, minf(1.0, delta * speed_lerp))
	var walking := _speed > walk_threshold
	if walking and not _walking:
		_start_clip(WALK_CLIP, _speed / clip_authored_speed)
		_walking = true
	elif walking and _walking:
		_player.speed_scale = clampf(_speed / clip_authored_speed, 0.6, 2.4)
	elif not walking and _walking:
		_stop_clip()
		_walking = false


func _start_clip(clip_name: StringName, speed_scale: float) -> void:
	var full_name := StringName("locomotion/%s" % clip_name)
	if not _player.has_animation(full_name):
		return
	# The clip owns the pose; the stance's per-frame writes would fight it.
	if _stance != null:
		_stance.set_process(false)
	_player.speed_scale = speed_scale
	_player.play(full_name)


func _stop_clip() -> void:
	if _player.current_animation != "":
		_player.stop()
	_player.speed_scale = 1.0
	# Back to rest, then let the stance re-own the pose.
	var skeleton := _find_skeleton()
	if skeleton != null:
		for bone_name: String in _touched_bones:
			var index := skeleton.find_bone(bone_name)
			if index < 0:
				continue
			var rest := skeleton.get_bone_rest(index)
			skeleton.set_bone_pose_rotation(index, rest.basis.get_rotation_quaternion())
			skeleton.set_bone_pose_position(index, rest.origin)
	if _stance != null:
		_stance.set_process(true)
		_stance.reapply()


func _find_skeleton() -> Skeleton3D:
	for node: Node in _model.find_children("*", "Skeleton3D", true, false):
		return node as Skeleton3D
	return null
