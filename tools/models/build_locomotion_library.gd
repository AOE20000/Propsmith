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
const CLIPS: PackedStringArray = ["walk", "idle", "run_067"]
## The author rig's Hips-height floor per clip, measured by probing the track
## keys (`vendor` probe in docs/local/akane_akayama.md §11).
const AUTHOR_HIPS_MIN := {"walk": 0.929, "idle": 0.982, "run_067": 0.901}


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
	for clip_name: String in CLIPS:
		if not source.has_animation(clip_name):
			push_warning("clip missing in source: " + clip_name)
			continue
		var clip := _retarget(source.get_animation(clip_name), skeleton,
			skeleton_name, hips_rest, float(AUTHOR_HIPS_MIN[clip_name]))
		clip.loop_mode = Animation.LOOP_LINEAR
		library.add_animation(clip_name, clip)
		print("[loco] %s: %d tracks kept, looped" % [clip_name, clip.get_track_count()])

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(
		OUT.get_base_dir()))
	var error := ResourceSaver.save(library, OUT)
	print("[loco] saved %s (exit %d)" % [OUT, error])
	figure.free()
	quit(0)


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
						# Re-anchor the authored bob to our rest height.
						value.y = hips_rest.y + (value.y - author_min)
					clip.position_track_insert_key(track_index, time, value)
				Animation.TYPE_ROTATION_3D:
					var value: Quaternion = source.track_get_key_value(index, key)
					clip.rotation_track_insert_key(track_index, time, value)
				Animation.TYPE_SCALE_3D:
					var value: Vector3 = source.track_get_key_value(index, key)
					clip.scale_track_insert_key(track_index, time, value)
	return clip
