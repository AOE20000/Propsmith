extends SceneTree
## Loop-closure check: for every clip, compare each bone's first and last
## keyframe. A loop that does not close snaps the pose back on every wrap —
## the "flash back to 100%" a sprinting player sees every ~0.24 s.

const LIBRARY := "res://assets/animations/locomotion.res"


func _init() -> void:
	var lib := load(LIBRARY) as AnimationLibrary
	if lib == null:
		print("[loop] FAIL: cannot load ", LIBRARY)
		quit(1)
		return
	for clip_name: StringName in lib.get_animation_list():
		var clip := lib.get_animation(clip_name)
		var worst_bone := ""
		var worst_rot := 0.0
		var worst_pos := 0.0
		for track: int in clip.get_track_count():
			var path := String(clip.track_get_path(track))
			var bone := path.get_slice(":", 1)
			var keys := clip.track_get_key_count(track)
			if keys < 2:
				continue
			match clip.track_get_type(track):
				Animation.TYPE_ROTATION_3D:
					var first: Quaternion = clip.track_get_key_value(track, 0)
					var last: Quaternion = clip.track_get_key_value(track, keys - 1)
					if first.angle_to(last) > worst_rot:
						worst_rot = first.angle_to(last)
						worst_bone = bone
				Animation.TYPE_POSITION_3D:
					var first: Vector3 = clip.track_get_key_value(track, 0)
					var last: Vector3 = clip.track_get_key_value(track, keys - 1)
					worst_pos = maxf(worst_pos, (first - last).length())
		print("[loop] %s: len=%.3f worst_rot=%.1f deg (%s) worst_pos=%.3f m" % [
			clip_name, clip.length, rad_to_deg(worst_rot), worst_bone, worst_pos])
	quit(0)
