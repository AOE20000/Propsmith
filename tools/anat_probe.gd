extends Node
## Anatomical check for the reported left-only leg twitch.
##
## The frame probe found the discontinuity is **one-sided**: over the same
## 237 frames the right ankle never moved more than 0.031 m while the left
## reached 0.131 m, and the left was never even planted (solve weight 0), so
## the foot IK is not what is moving it. That points at the clip's own left leg
## track, or at the skeleton's left leg being longer / differently parented.
##
## Everything here is read-only. It prints the bone chain, the rest lengths and
## the measured clip motion per side, so the asymmetry can be seen rather than
## inferred.

var _skel: Skeleton3D
var _clips: ModelClips
var _bones: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var packed: PackedScene = load("res://src/boot/startup.tscn") as PackedScene
	add_child(packed.instantiate())
	Events.world_ready.connect(_on_world_ready)


func _on_world_ready(_world: Node3D) -> void:
	var player := get_tree().get_first_node_in_group(&"player") as Player
	if player == null:
		print("[anat-probe] FAIL: no player")
		get_tree().quit(1)
		return
	var model := player.get_node_or_null("PlayerModel") as Node3D
	if model == null:
		print("[anat-probe] FAIL: no PlayerModel")
		get_tree().quit(1)
		return
	_clips = model.get_node_or_null("Clips") as ModelClips
	for node: Node in model.find_children("*", "Skeleton3D", true, false):
		_skel = node as Skeleton3D
		break
	if _skel == null:
		print("[anat-probe] FAIL: no skeleton")
		get_tree().quit(1)
		return
	_report_chain()
	_report_clip_tracks()
	get_tree().quit(0)


func _report_chain() -> void:
	print("[anat-probe] --- bone chains (rest lengths are origin-to-origin) ---")
	for side: String in ["Left", "Right"]:
		var parts: Array[String] = []
		var prev_name := ""
		for seg: String in ["UpperLeg", "LowerLeg", "Foot", "ToeBase"]:
			var name := "%s%s" % [side, seg]
			var idx := _skel.find_bone(name)
			if idx < 0:
				parts.append("%s=MISSING" % name)
				continue
			var parent := _skel.get_bone_parent(idx)
			if parent >= 0:
				# The origin-to-origin distance: the rest basis Y length is
				# always 1.0 in Godot (rotations are stored scale-free), so the
				# length has to be measured between the two bone origins.
				var rest: float = _skel.get_bone_global_rest(parent).origin.distance_to(
					_skel.get_bone_global_rest(idx).origin)
				parts.append("%s[parent=%s len=%.4f]" % [
					name, _skel.get_bone_name(parent), rest
				])
			else:
				parts.append("%s[ROOT]" % name)
			prev_name = name
		print("[anat-probe] %s" % "  ".join(parts))
	var hips := _skel.find_bone(&"Hips")
	if hips >= 0:
		print("[anat-probe] hips origin %s" % str(_skel.get_bone_global_rest(hips).origin))


## Which bones the locomotion clip actually writes, and how far it moves each
## per cycle. A side that the clip barely animates would let the IK own it
## (or the reverse), and a side whose track is broken reads as a leg that
## snaps back once per stride — the reported symptom.
func _report_clip_tracks() -> void:
	if _clips == null:
		print("[anat-probe] no Clips component")
		return
	print("[anat-probe] --- clip touched bones (%d) ---" % _clips._touched_bones.size())
	var interesting: Array[String] = []
	for bone: String in _clips._touched_bones:
		if bone.contains("Leg") or bone.contains("Foot") or bone.contains("Hips") \
				or bone.contains("Toe"):
			interesting.append(bone)
	print("[anat-probe] leg/foot tracks: %s" % str(interesting))
	# Per-side presence, which is the asymmetry the report is about.
	for side: String in ["Left", "Right"]:
		var hits: Array[String] = []
		for bone: String in _clips._touched_bones:
			if bone.begins_with(side):
				hits.append(bone)
		print("[anat-probe] %s side tracks: %s" % [side, str(hits)])