extends Node
## Does a proportion slider actually change the mesh now, and does the figure
## still stand on the ground afterwards?
##
## The name resolution is only half of it: `0/21` used to mean every slider was
## a no-op, and resolving 17/17 only means the writes now land. What has to be
## checked next is whether a write at full strength (a) changes the rest in the
## expected direction and (b) leaves the feet where they were, since the
## re-anchoring exists precisely to stop a length edit from lifting or sinking
## the figure.
##
## The apply path is a static that needs a CharacterState, so this drives the
## public one and reads the rests and the skeleton height back.
var _skel: Skeleton3D
var _conv: StringName
var _baseline: Dictionary = {}

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(load("res://src/boot/startup.tscn").instantiate())
	Events.world_ready.connect(_w)

func _w(_x: Node3D) -> void:
	var p := get_tree().get_first_node_in_group(&"player") as Player
	var m := p.get_node_or_null("PlayerModel") as Node3D
	for n: Node in m.find_children("*", "Skeleton3D", true, false):
		_skel = n as Skeleton3D
		break
	_conv = CharacterAppearance.detect_rig_convention(_skel)
	# Clear the cached baseline so the probe measures a cold apply, the way a
	# figure being dressed for the first time would.
	_skel.remove_meta(&"appearance_rest_baseline")
	_skel.remove_meta(&"appearance_rig_convention")
	_skel.remove_meta(&"appearance_base_y")
	_baseline = {}
	for i: int in _skel.get_bone_count():
		_baseline[_skel.get_bone_name(i)] = _skel.get_bone_rest(i).basis.y.length()
	_run()
	get_tree().quit(0)

func _run() -> void:
	var state := CharacterState.new()
	print("[act] convention %s, baseline hip rest y-scale %.4f, skeleton y %.4f" % [
		String(_conv), _rest_y(&"Hips"), _skel.position.y])
	# Leg length at full strength: the group that moves the foot the most, so
	# the re-anchoring has something to do.
	state.values[&"leg_length"] = 1.0
	CharacterAppearance._apply_deforms(state, _skel)
	var after := _rest_y(&"Hips")
	print("[act] leg_length=+1.0 → hip rest y-scale %.4f (was %.4f)" % [after, _baseline[&"Hips"]])
	print("[act]   skeleton y %.4f  (re-anchored; the feet should not have moved)" % _skel.position.y)
	var thigh := CharacterAppearance.resolve_role(_skel, "LeftUpperLeg", _conv)
	print("[act]   %s rest y-scale %.4f → %.4f" % [
		thigh, _baseline[thigh], _rest_y(thigh)])
	# Back to zero: the pass is a reset-and-rebuild, so this must return the
	# original value rather than accumulate.
	state.values[&"leg_length"] = 0.0
	CharacterAppearance._apply_deforms(state, _skel)
	print("[act] leg_length=0.0 → %s rest y-scale %.4f (authored %.4f)" % [
		thigh, _rest_y(thigh), _baseline[thigh]])

func _rest_y(name: String) -> float:
	var i: int = _skel.find_bone(StringName(name))
	return 0.0 if i < 0 else _skel.get_bone_rest(i).basis.y.length()
