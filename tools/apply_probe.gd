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
var _authored_span: float = 0.0
var _baseline_origin: Dictionary = {}

func _rest_origin_y(name: String) -> float:
	var i: int = _skel.find_bone(StringName(name))
	return 0.0 if i < 0 else _skel.get_bone_rest(i).origin.y
var _ground: float = 0.0

func _sole_y() -> float:
	return _world_rest_y(&"LeftFoot")

func _hip_y() -> float:
	return _world_rest_y(&"LeftUpperLeg")

func _world_rest_y(name: StringName) -> float:
	var i: int = _skel.find_bone(name)
	return 0.0 if i < 0 else _skel.get_bone_global_rest(i).origin.y

func _ground_y() -> float:
	if is_equal_approx(_ground, 0.0):
		var sp := _skel.get_world_3d().direct_space_state
		if sp != null:
			var from := Vector3(0.0, _world_rest_y(&"Hips") + 0.3, 0.0)
			var to := Vector3(0.0, _world_rest_y(&"Hips") - 1.5, 0.0)
			var q := PhysicsRayQueryParameters3D.create(from, to, 1)
			var h: Dictionary = sp.intersect_ray(q)
			if not h.is_empty():
				_ground = (h["position"] as Vector3).y
	return _ground

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
	_authored_span = _sole_y() - _hip_y()
	_baseline_origin = {}
	for i: int in _skel.get_bone_count():
		_baseline_origin[_skel.get_bone_name(i)] = _skel.get_bone_rest(i).origin.y
	_baseline = {}
	for i: int in _skel.get_bone_count():
		# Record the authored *length*, the same quantity the edit changes.
		_baseline[_skel.get_bone_name(i)] = _length_of(i)
	_run()
	get_tree().quit(0)

func _run() -> void:
	var state := CharacterState.new()
	print("[act] convention %s, baseline hips length %.4f, skeleton y %.4f" % [
		String(_conv), _rest_y(&"Hips"), _skel.position.y])
	# Leg length at full strength: the group that moves the foot the most, so
	# the re-anchoring has something to do.
	state.values[&"leg_length"] = 1.0
	CharacterAppearance._apply_deforms(state, _skel)
	var after := _rest_y(&"Hips")
	print("[act] leg_length=+1.0 → hips length %.4f (was %.4f)" % [after, _baseline[&"Hips"]])
	print("[act]   skeleton y %.4f  (re-anchored; the feet should not have moved)" % _skel.position.y)
	var thigh := CharacterAppearance.resolve_role(_skel, "LeftUpperLeg", _conv)
	print("[act]   %s length %.4f → %.4f" % [
		thigh, _baseline[thigh], _rest_y(thigh)])
	# The number that actually decides whether this works: the sole's height
	# above the ground. A longer leg must not lift the figure off the floor —
	# that is what the re-anchoring is for — and the *span* from hip to foot
	# must have actually grown, which is what the slider is for.
	# The rest origins, read straight off the bones. `get_bone_global_rest`
	# composes a cached chain and did not reflect the edit within the same
	# frame, which made the span read as unchanged while the origin had moved —
	# the probe disagreed with itself and the origin is the part that was
	# actually written.
	var thigh_origin: float = _rest_origin_y(thigh)
	var shin: String = CharacterAppearance.resolve_role(_skel, "LeftLowerLeg", _conv)
	print("[act]   %s rest.origin.y %.5f → %.5f" % [
		thigh, _baseline_origin[thigh], thigh_origin])
	if not shin.is_empty():
		print("[act]   %s rest.origin.y %.5f → %.5f" % [
			shin, _baseline_origin[shin], _rest_origin_y(shin)])
	print("[act]   leg span (sum of segment lengths) authored %.5f" % _authored_span)
	print("[act]   sole y %.4f  ground y %.4f  (sole should sit on the ground)" % [
		_sole_y(), _ground_y()])
	# Applying the SAME state again must be a no-op — the panel fires this pass
	# on every edit, so a drifting anchor shows up as the figure creeping.
	var after_first: float = _skel.position.y
	CharacterAppearance._apply_deforms(state, _skel)
	print("[act] same state again → skeleton y %.4f → %.4f (drift %+.4f; must be 0)" % [
		after_first, _skel.position.y, _skel.position.y - after_first])
	# Back to zero: the pass is a reset-and-rebuild, so this must return the
	# original value rather than accumulate.
	state.values[&"leg_length"] = 0.0
	CharacterAppearance._apply_deforms(state, _skel)
	print("[act] leg_length=0.0 → %s length %.4f (authored %.4f), skeleton y %.4f (started 0)" % [
		thigh, _rest_y(thigh), _baseline[thigh], _skel.position.y])

## The bone's length: the distance from its parent's rest origin to its own.
## This is the quantity a proportion slider changes, and the one a probe has to
## read back — a scaled rest basis reads 1.0 either way, which is exactly how
## the first version of this looked like it worked while the figure only moved.
func _length_of(index: int) -> float:
	var parent: int = _skel.get_bone_parent(index)
	if parent < 0:
		return _skel.get_bone_rest(index).origin.length()
	return _skel.get_bone_rest(parent).origin.distance_to(_skel.get_bone_rest(index).origin)


## Legacy alias kept so the two readers above read the same thing.
## The bone's LENGTH, which is what a proportion slider is supposed to change:
## the distance between this bone's rest origin and its parent's. Reading the
## basis scale instead is what made the earlier version look like it worked
## while the figure only moved.
func _rest_y(name: String) -> float:
	var i: int = _skel.find_bone(StringName(name))
	if i < 0:
		return 0.0
	var parent: int = _skel.get_bone_parent(i)
	if parent < 0:
		return _skel.get_bone_rest(i).origin.length()
	return _skel.get_bone_rest(parent).origin.distance_to(_skel.get_bone_rest(i).origin)
