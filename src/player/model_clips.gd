extends Node
class_name ModelClips
## Locomotion clips for the shared base figure, driven by measured speed —
## the animation half of "on demand": a figure that stands still costs no
## clip evaluation, and one that walks gets a real stride instead of sliding.
##
## The clips come from `assets/animations/locomotion.res` (built by
## `tools/models/build_locomotion_library.gd` from catprisbrey's open
## ShooterLib, CC-BY 4.0): `walk`, `idle` and `run`, retargeted onto our
## skeleton's own node and bone names at build time, with the author rig's
## Hips-height re-anchored to ours.
##
## ## Implementation note (2026-10-04): poses are applied **manually** — the
## clip is sampled with `Animation.track_interpolate` each frame and written
## straight into the skeleton with `set_bone_pose_*`. The AnimationMixer was
## measured to advance its cursor **without ever writing a single bone** in
## this build (Godot 4.7.2): every callback mode, wiring order, cache reset
## and explicit `advance()` — reproduced on a minimal code-built rig, see
## `tools/mini_rig_probe.gd`. Manual sampling removes that entire failure
## surface, and this component needs none of the mixer's machinery anyway:
## one clip, looped, speed-scaled, no blending.
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
## The run gear's clip. Built by `build_locomotion_library` from `sneak-run-s`
## — a *true loop* (first and last keys identical), unlike the root-motion
## clip this slot previously held, whose 3.6 m first/last key mismatch snapped
## the pose back on every wrap.
const RUN_CLIP: StringName = &"run"
## The ground speed the walk clip was authored for (m/s). Playback speed
## divides the measured speed by this, so faster movement plays the cycle
## proportionally faster instead of moonwalking at a fixed cadence.
@export var clip_authored_speed: float = 1.3
## The same for the run clip. Sprint (8.6 m/s) maps to ~2.5× — the cap below
## keeps it inside the clip's believable stride.
@export var run_authored_speed: float = 3.4
## Speed above which the figure runs instead of walks (m/s). The walk speed
## (5.2) stays below it, the sprint (8.6) crosses it.
@export var run_threshold: float = 6.5
## Minimum seconds a walk/run gear holds before the other gear may take over —
## the same anti-flicker hysteresis the reference movement system calls
## RunToWalkTime: a measured speed hovering near the threshold must not flip
## the clip every frame.
@export var gear_hold: float = 0.3
## Speed above which the figure counts as walking (m/s).
@export var walk_threshold: float = 0.25
## How quickly playback speed follows measured speed (per second).
@export var speed_lerp: float = 6.0
## Seconds for the pose to blend from the moving clip into the standing stance
## when the figure stops. Short enough to feel like deceleration, long enough
## that no single frame carries the whole pose change.
@export var stop_blend: float = 0.18
## Library injection for tests and probes: when set, it replaces the resource
## at `LIBRARY_PATH` (which needs an import pass a headless test may not run).
var library_override: AnimationLibrary = null

var _model: Node3D = null
var _skeleton: Skeleton3D = null
var _library: AnimationLibrary = null
var _stance: ModelStance = null
var _current_clip: Animation = null
## Track index → skeleton bone index, resolved once per started clip.
var _track_bones: PackedInt32Array = PackedInt32Array()
## The union of every bone the locomotion clips touch — the set that must be
## restored when the clips stop, so a figure doesn't idle in mid-stride.
var _touched_bones: PackedStringArray = []
var _last_position: Vector3 = Vector3.ZERO
var _speed: float = 0.0
var _walking: bool = false
var _running: bool = false
## Seconds the current gear has held — the hysteresis budget for switching.
var _gear_time: float = 0.0
## Stop-transition state: the snapshot the pose blends from, its elapsed time,
## and whether a blend is in progress.
var _blend_active: bool = false
var _blend_t: float = 0.0
var _blend_from: Dictionary = {}
var _time: float = 0.0
var _forced: StringName = &""


## Bind to a model root and resolve the pieces the manual sampler needs:
## the skeleton, the stance (to mute while a clip owns the pose) and the clip
## library. A model without a skeleton or the library simply never walks
## (capsule fallback).
func setup(model: Node3D) -> void:
	_model = model
	if model == null:
		return
	_skeleton = _find_skeleton()
	_stance = model.get_node_or_null("Stance") as ModelStance
	if library_override != null:
		_library = library_override
	elif ResourceLoader.exists(LIBRARY_PATH):
		_library = load(LIBRARY_PATH) as AnimationLibrary
	if _library != null:
		_touched_bones = _collect_bones(_library)
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
	_start_clip(clip_name)

func _process(delta: float) -> void:
	if _model == null or _library == null or _skeleton == null:
		return
	if not _model.is_inside_tree():
		return
	# A forced clip (probe photography) owns the sampling loop entirely.
	if not _forced.is_empty():
		var forced_clip: Animation = _current_clip
		if forced_clip != null:
			_time = fmod(_time + delta, forced_clip.length)
			_apply_sampled_pose(forced_clip, _time)
		return
	var displacement := _model.global_position - _last_position
	_last_position = _model.global_position
	displacement.y = 0.0
	var speed := displacement.length() / maxf(delta, 1e-4)
	_decide_gear(delta, speed)


## The whole locomotion brain, as a pure function of measured speed — walking
## state machine, gear hysteresis, clip time and pose sampling in one place.
## Isolated from `_process` so tests can drive it with exact speeds instead of
## fighting the engine's own ticks over the same accumulator.
func _decide_gear(delta: float, measured_speed: float) -> void:
	_speed = lerpf(_speed, measured_speed, minf(1.0, delta * speed_lerp))
	var walking := _speed > walk_threshold
	if walking and not _walking:
		# Walking again cancels any stop blend in progress: the pose continues
		# from wherever the blend had reached, which is exactly what a human
		# does when they change their mind mid-deceleration.
		_blend_active = false
		_start_clip(WALK_CLIP)
		_walking = true
		_running = false
		_gear_time = 0.0
	if walking and _walking:
		# Gear selection with hold-time hysteresis: the measured speed hovers
		# around the threshold during acceleration, and without the hold the
		# clip flips walk/run every frame (the reference system's
		# RunToWalkTime, same reason).
		_gear_time += delta
		var want_run := _speed > run_threshold
		if want_run != _running and _gear_time >= gear_hold:
			_running = want_run
			_gear_time = 0.0
			_start_clip(RUN_CLIP if _running else WALK_CLIP, true)
		# A gear switch to a clip the library lacks (or any path that lost the
		# current one) must not sample into null — fall back to the walk clip.
		if _current_clip == null:
			_start_clip(WALK_CLIP)
			if _current_clip == null:
				return
		var authored := run_authored_speed if _running else clip_authored_speed
		_time = fmod(
			_time + delta * clampf(_speed / authored, 0.6, 2.4),
			_current_clip.length
		)
		_apply_sampled_pose(_current_clip, _time)
	elif not walking and _walking:
		_begin_stop_blend()
		_walking = false
		_running = false
	elif not walking and not _walking:
		_advance_stop_blend(delta)


## Snapshot the moving pose and start blending it into the standing stance.
##
## The old exit was `_stop_clip()`: every touched bone snapped to rest inside
## one frame — from a full stride to a statue, the "brakes slam" look. The
## snapshot is the clip's last pose; the blend target is rest put through the
## stance's arm aims, recomputed each blended frame by `_write_stand_target`.
##
## The stance's own processing stays muted for the duration (its breathing
## writes would fight the blend); it is handed the pose back when the blend
## finishes.
func _begin_stop_blend() -> void:
	if _skeleton == null or _touched_bones.is_empty():
		_stop_clip()
		return
	_blend_from.clear()
	for bone_name: String in _touched_bones:
		var index := _skeleton.find_bone(bone_name)
		if index < 0:
			continue
		_blend_from[bone_name] = {
			"rot": _skeleton.get_bone_pose_rotation(index),
			"pos": _skeleton.get_bone_pose_position(index),
			"scale": _skeleton.get_bone_pose_scale(index),
		}
	_blend_active = true
	_blend_t = 0.0
	_current_clip = null


## One blended frame of the stop transition: write the standing target, then
## slerp every touched bone from the snapshot toward it. Smoothstep weight so
## both the start and the end of the deceleration ease — a linear ramp reads
## as a mechanical snap at the endpoints.
func _advance_stop_blend(delta: float) -> void:
	if not _blend_active:
		return
	_blend_t += delta
	var weight := clampf(_blend_t / stop_blend, 0.0, 1.0)
	var eased := weight * weight * (3.0 - 2.0 * weight)
	_write_stand_target()
	for bone_name: String in _touched_bones:
		var index := _skeleton.find_bone(bone_name)
		if index < 0 or not _blend_from.has(bone_name):
			continue
		var from: Dictionary = _blend_from[bone_name]
		_skeleton.set_bone_pose_rotation(index, (from["rot"] as Quaternion).slerp(
			_skeleton.get_bone_pose_rotation(index), eased))
		_skeleton.set_bone_pose_position(index, (from["pos"] as Vector3).lerp(
			_skeleton.get_bone_pose_position(index), eased))
		_skeleton.set_bone_pose_scale(index, (from["scale"] as Vector3).lerp(
			_skeleton.get_bone_pose_scale(index), eased))
	if weight >= 1.0:
		_blend_active = false
		if _stance != null:
			_stance.set_process(true)


## The blend's target: rest for every touched bone, then the stance's arm aims
## written over it. Idempotent, so calling it once per blended frame is safe.
func _write_stand_target() -> void:
	for bone_name: String in _touched_bones:
		var index := _skeleton.find_bone(bone_name)
		if index < 0:
			continue
		var rest := _skeleton.get_bone_rest(index)
		_skeleton.set_bone_pose_rotation(index, rest.basis.get_rotation_quaternion())
		_skeleton.set_bone_pose_position(index, rest.origin)
		_skeleton.set_bone_pose_scale(index, rest.basis.get_scale())
	if _stance != null:
		_stance.reapply()


func _start_clip(clip_name: StringName, keep_phase: bool = false) -> void:
	if _library == null or not _library.has_animation(clip_name):
		return
	var next: Animation = _library.get_animation(clip_name)
	if keep_phase and _current_clip != null and _current_clip.length > 0.0:
		# Carry the cycle phase across the gear switch: walking and running
		# loops differ in length, but keeping the *ratio* means the stride
		# continues from the same leg instead of snapping to step one.
		_time = fmod(_time / _current_clip.length * next.length, next.length)
	else:
		_time = 0.0
	_current_clip = next
	_resolve_track_bones(_current_clip)
	# The clip owns the pose; the stance's per-frame writes would fight it.
	if _stance != null:
		_stance.set_process(false)


## Manual sampling: the whole point of this component. The per-type
## `track_interpolate` reads the blended keyframe value, `set_bone_pose_*`
## writes it — both measured to work where the mixer's own application does not.
func _apply_sampled_pose(clip: Animation, time: float) -> void:
	for track: int in clip.get_track_count():
		var bone := _track_bones[track]
		if bone < 0:
			continue
		match clip.track_get_type(track):
			Animation.TYPE_ROTATION_3D:
				_skeleton.set_bone_pose_rotation(
					bone, clip.rotation_track_interpolate(track, time))
			Animation.TYPE_POSITION_3D:
				_skeleton.set_bone_pose_position(
					bone, clip.position_track_interpolate(track, time))
			Animation.TYPE_SCALE_3D:
				_skeleton.set_bone_pose_scale(
					bone, clip.scale_track_interpolate(track, time))


## Resolve each track's bone name once per started clip: `find_bone` walks the
## whole bone list, which must not ride on every frame.
func _resolve_track_bones(clip: Animation) -> void:
	_track_bones = PackedInt32Array()
	_track_bones.resize(clip.get_track_count())
	for track: int in clip.get_track_count():
		var bone_name := String(clip.track_get_path(track)).get_slice(":", 1)
		_track_bones[track] = _skeleton.find_bone(bone_name)


func _stop_clip() -> void:
	_current_clip = null
	# Back to rest — rotation, position **and** scale (the walk cycle moves
	# Hips' position and the breathing rig scales Chest), then let the stance
	# re-own the pose.
	if _skeleton != null:
		for bone_name: String in _touched_bones:
			var index := _skeleton.find_bone(bone_name)
			if index < 0:
				continue
			var rest := _skeleton.get_bone_rest(index)
			_skeleton.set_bone_pose_rotation(index, rest.basis.get_rotation_quaternion())
			_skeleton.set_bone_pose_position(index, rest.origin)
			_skeleton.set_bone_pose_scale(index, rest.basis.get_scale())
	if _stance != null:
		_stance.set_process(true)
		_stance.reapply()


func _find_skeleton() -> Skeleton3D:
	for node: Node in _model.find_children("*", "Skeleton3D", true, false):
		return node as Skeleton3D
	return null
