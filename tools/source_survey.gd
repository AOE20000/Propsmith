extends SceneTree
## Source-library survey: list every clip in the vendor libraries with length
## and loop-closure error, so a genuinely looping run cycle can be picked
## instead of run_067 (a non-looping clip whose first/last keys differ by
## 3.6 m — looping it snaps the pose back every wrap).

const SOURCES: PackedStringArray = [
	"res://vendor/anim/ShooterLib.res",
	"res://vendor/anim/MeleeLib.res",
]


func _init() -> void:
	for source_path: String in SOURCES:
		var lib := load(source_path) as AnimationLibrary
		if lib == null:
			print("[src] cannot load ", source_path)
			continue
		print("[src] === %s ===" % source_path)
		for clip_name: StringName in lib.get_animation_list():
			var clip := lib.get_animation(clip_name)
			var worst_pos := 0.0
			var worst_rot := 0.0
			for track: int in clip.get_track_count():
				var keys := clip.track_get_key_count(track)
				if keys < 2:
					continue
				match clip.track_get_type(track):
					Animation.TYPE_ROTATION_3D:
						var a: Quaternion = clip.track_get_key_value(track, 0)
						var b: Quaternion = clip.track_get_key_value(track, keys - 1)
						worst_rot = maxf(worst_rot, a.angle_to(b))
					Animation.TYPE_POSITION_3D:
						var a: Vector3 = clip.track_get_key_value(track, 0)
						var b: Vector3 = clip.track_get_key_value(track, keys - 1)
						worst_pos = maxf(worst_pos, (a - b).length())
			print("[src]   %-24s len=%.3f pos_err=%.3f rot_err=%.1f deg tracks=%d" % [
				clip_name, clip.length, worst_pos,
				rad_to_deg(worst_rot), clip.get_track_count()])
	quit(0)
