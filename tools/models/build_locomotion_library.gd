extends SceneTree
## Build `assets/animations/locomotion.res` — a small AnimationLibrary with the
## locomotion clips our figures use, retargeted onto the base figure's skeleton.
##
## Source: catprisbrey/Godot4-OpenAnimationLibraries, `ShooterLib.res`
## (CC-BY 4.0, open user-created animations — the repo's Mixamo-derived
## libraries were removed for Adobe ToS reasons; these remain shareable).
## That library was authored on a skeleton literally named `GeneralSkeleton`
## with SkeletonProfileHumanoid bone names — the same names the VRM importer
## normalises our skeleton to, so retargeting is a track-path rewrite plus a
## bone filter, no re-baking.
##
## Three fixes happen here, once, so the runtime never sees them:
##   1. tracks for bones our rig lacks (UpperChest, the profile finger set,
##      DEF-breast) are dropped instead of erroring at playback;
##   2. track paths are rewritten from the author's `%GeneralSkeleton` (a
##      unique-name reference their scene carries) to our plain node path;
##   3. the Hips *position* track is in the author rig's scale (their hips sit
##      near 0.95 m; ours at 0.853 m) — played unmodified it would hoist the
##      pelvis up and stretch the legs. The vertical offset is re-anchored to
##      our rest height, preserving the authored bob.
##
## Run: godot --headless --path . --script tools/models/build_locomotion_library.gd

const SOURCE := "res://vendor/anim/ShooterLib.res"
const OUT := "res://assets/animations/locomotion.res"
const FIGURE := "res://assets/characters/base_female.vrm"
## Output name → source clip. The output side is deliberately semantic (`run`),
## so swapping which source clip provides a gait is a one-line change here and
## nothing at runtime moves.
##
## `run` used to be `run_067`, which is a *root-motion* clip: its first and last
## keys differ by 3.6 m, so looping it snaps the pose (and the pelvis) back to
## the start every 0.58 s — the sprint "moves, then flashes back" report.
## `sneak-run-s` is the same length and closes perfectly (0.000 m), at the cost
## of a lower, crouched run silhouette — the closest true loop the library has.
const CLIP_SOURCES: Dictionary = {
	"walk": "walk",
	"idle": "idle",
	"run": "sneak-run-s",
	# Airborne: `jump` is a 0.21 s action (leap and tuck) played once and held
	# at its last frame; `fall` is a true loop (first/last keys identical).
	"jump": "jump",
	"fall": "fall",
}


func _init() -> void:
	var source := load(SOURCE) as AnimationLibrary
	if source == null:
		push_error("source library not found: " + SOURCE)
		quit(1)
		return
	var packed := load(FIGURE) as PackedScene
	var figure := packed.instantiate()
	var skeleton: Skeleton3D = null
	for node: Node in figure.find_children("*", "Skeleton3D", true, false):
		skeleton = node as Skeleton3D
		break
	var skeleton_name := String(skeleton.name)
	var hips_rest: Vector3 = skeleton.get_bone_rest(
		skeleton.find_bone("Hips")).origin
	print("[loco] skeleton=%s bones=%d hips_rest=%s" % [
		skeleton_name, skeleton.get_bone_count(), hips_rest])

	var library := AnimationLibrary.new()
	for output_name: String in CLIP_SOURCES:
		var source_name: String = CLIP_SOURCES[output_name]
		if not source.has_animation(source_name):
			push_warning("clip missing in source: " + source_name)
			continue
		var source_clip := source.get_animation(source_name)
		var clip := _retarget(source_clip, skeleton, skeleton_name, hips_rest,
			_hips_min_y(source_clip))
		clip.loop_mode = Animation.LOOP_LINEAR
		library.add_animation(output_name, clip)
		print("[loco] %s (from %s): %d tracks kept, looped" % [
			output_name, source_name, clip.get_track_count()])

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(
		OUT.get_base_dir()))
	var error := ResourceSaver.save(library, OUT)
	print("[loco] saved %s (exit %d)" % [OUT, error])
	figure.free()
	quit(0)


## The clip's lowest Hips height, measured from its own keys rather than kept as
## a hand-tuned constant per clip: the re-anchor below needs it, and a constant
## silently goes stale the moment the source clip is swapped.
func _hips_min_y(clip: Animation) -> float:
	var lowest := INF
	for track: int in clip.get_track_count():
		if clip.track_get_type(track) != Animation.TYPE_POSITION_3D:
			continue
		if String(clip.track_get_path(track)).get_slice(":", 1) != "Hips":
			continue
		for key: int in clip.track_get_key_count(track):
			var v: Vector3 = clip.track_get_key_value(track, key)
			lowest = minf(lowest, v.y)
	return lowest if lowest < INF else 0.0


func _retarget(source: Animation, skeleton: Skeleton3D, skeleton_name: String,
		hips_rest: Vector3, author_min: float) -> Animation:
	var clip := Animation.new()
	clip.length = source.length
	for index: int in source.get_track_count():
		var path := String(source.track_get_path(index))
		if not path.contains(":"):
			continue
		var bone := path.get_slice(":", 1)
		if skeleton.find_bone(bone) < 0:
			continue
		var track_type := source.track_get_type(index)
		var new_path := "%s:%s" % [skeleton_name, bone]
		var track_type_name := ""
		match track_type:
			Animation.TYPE_POSITION_3D:
				track_type_name = "position"
			Animation.TYPE_ROTATION_3D:
				track_type_name = "rotation"
			Animation.TYPE_SCALE_3D:
				track_type_name = "scale"
			_:
				continue
		var key_count := source.track_get_key_count(index)
		# Diagnostic: the hips' horizontal travel in the source clip. If the
		# author animated real forward motion (root-motion style), an in-place
		# player rig must not inherit it — see the re-anchor below.
		if bone == "Hips" and track_type == Animation.TYPE_POSITION_3D:
			var min_x := INF
			var max_x := -INF
			var min_z := INF
			var max_z := -INF
			for key: int in key_count:
				var v: Vector3 = source.track_get_key_value(index, key)
				min_x = minf(min_x, v.x)
				max_x = maxf(max_x, v.x)
				min_z = minf(min_z, v.z)
				max_z = maxf(max_z, v.z)
			print("[loco]   %s Hips x/z travel: x %.3f..%.3f, z %.3f..%.3f" % [
				skeleton_name, min_x, max_x, min_z, max_z])
		var track_index := clip.add_track(track_type)
		clip.track_set_path(track_index, new_path)
		for key: int in key_count:
			var time := source.track_get_key_time(index, key)
			match track_type:
				Animation.TYPE_POSITION_3D:
					# The key's own value — `track_get_key_value`. The previous
					# version passed the key *index* into `*_track_interpolate`,
					# whose second parameter is a *time*: key 2 sampled the clip
					# at 2.0 s, past its length, clamping to the final pose —
					# every clip played its first two keys and then froze.
					var value: Vector3 = source.track_get_key_value(index, key)
					if bone == "Hips":
						# In-place locomotion: the authored clip can carry real
						# forward motion in the hips' x/z (root-motion style).
						# Played on an in-game character it would shove the
						# visual model ahead of its physics body and snap back
						# on every loop — the sprint "200% then flash back"
						# report. Keep only the authored bob (y), re-anchored
						# to our rest height; x/z stay at rest.
						value.x = hips_rest.x
						value.z = hips_rest.z
						value.y = hips_rest.y + (value.y - author_min)
					clip.position_track_insert_key(track_index, time, value)
				Animation.TYPE_ROTATION_3D:
					var value: Quaternion = source.track_get_key_value(index, key)
					clip.rotation_track_insert_key(track_index, time, value)
				Animation.TYPE_SCALE_3D:
					var value: Vector3 = source.track_get_key_value(index, key)
					clip.scale_track_insert_key(track_index, time, value)
	return clip
