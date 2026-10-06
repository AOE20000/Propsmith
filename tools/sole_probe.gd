extends Node
## Sole-to-ankle geometry, measured from the model's actual mesh.
##
## The report says: walking sinks the figure but the shoe sole ends up *under*
## the ground, standing is fine, and **removing the shoes leaves the feet
## floating above the ground**. Those three together are a height-offset
## problem, and the offset that matters is not the one in the source — it is
## the distance from the ankle *bone* to the lowest point of the geometry that
## represents the sole, because that is the number the plant test pins against
## and `ANKLE_HEIGHT` claims to stand in for.
##
## If `ANKLE_HEIGHT` is larger than the real bone-to-sole distance, the plant
## puts the *bone* too high, the mesh hangs below it, and the sole ends up
## under the ground — which is the walking report exactly. Barefoot, the same
## geometry is shorter, so the figure floats instead. Both symptoms from one
## wrong constant.
##
## Read-only. Measures the mesh AABB per side and reports the numbers so the
## constant can be set from the model rather than guessed.

var _skel: Skeleton3D
var _ik: ModelFootIK
var _feet: Array[int] = [-1, -1]
var _lower: Array[int] = [-1, -1]


var _frames: int = 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var packed: PackedScene = load("res://src/boot/startup.tscn") as PackedScene
	add_child(packed.instantiate())
	Events.world_ready.connect(_on_world_ready)


## The sole measurement is deferred to the component's first update (the model
## has no real transforms at `setup`), so the probe waits for a few frames
## before reading it — otherwise it reports the fallback and looks like the
## measurement failed.
func _process(_delta: float) -> void:
	_frames += 1
	if _frames == 12:
		_finish()


func _finish() -> void:
	# Report the measured value first: everything below it is arithmetic on top
	# of that number, so reading the fallback and then printing the rest would
	# report figures that do not correspond to the constant in force.
	_report_sole_heights()
	_report_ankle_rest()
	_report_clearance_at_rest()
	get_tree().quit(0)


func _on_world_ready(_world: Node3D) -> void:
	var player := get_tree().get_first_node_in_group(&"player") as Player
	if player == null:
		print("[sole-probe] FAIL: no player")
		get_tree().quit(1)
		return
	var model := player.get_node_or_null("PlayerModel") as Node3D
	if model == null:
		print("[sole-probe] FAIL: no PlayerModel")
		get_tree().quit(1)
		return
	for node: Node in model.find_children("*", "Skeleton3D", true, false):
		_skel = node as Skeleton3D
		break
	if _skel == null:
		print("[sole-probe] FAIL: no skeleton")
		get_tree().quit(1)
		return
	_ik = _skel.get_node_or_null("FootIK") as ModelFootIK
	if _ik != null:
		# The component measures its own sole offset on its first update, which
		# happens before this probe can switch the log on. Re-run it here so the
		# number and any accept/reject reason are both visible — the measurement
		# is idempotent and the model is in the tree by now.
		_ik._verbose_measurement = true
		_ik._sole_measured = false
		_ik._sole_attempts = 0
	_feet[0] = _skel.find_bone(&"LeftFoot")
	_feet[1] = _skel.find_bone(&"RightFoot")
	_lower[0] = _skel.find_bone(&"LeftLowerLeg")
	_lower[1] = _skel.find_bone(&"RightLowerLeg")
	if _feet[0] < 0 or _feet[1] < 0:
		print("[sole-probe] FAIL: no LeftFoot/RightFoot bones")
		get_tree().quit(1)


## The heart of it: for each side, how far the geometry's lowest point sits
## below the ankle bone. That distance is what the ground clearance physically
## means, and it is what `ANKLE_HEIGHT` has to equal for a planted foot to rest
## *on* the ground rather than through it.
func _report_sole_heights() -> void:
	print("[sole-probe] --- bone-to-sole geometry ---")
	print("[sole-probe] ANKLE_HEIGHT fallback = %.4f m" % ModelFootIK.ANKLE_HEIGHT)
	if _ik != null:
		print("[sole-probe] measured sole drop  = %.4f m (this is what the plant test now uses)" % _ik.sole_drop())
	else:
		print("[sole-probe] no FootIK mounted; cannot read the measured drop")
	for side: int in 2:
		var foot := _feet[side]
		var lower := _lower[side]
		if foot < 0 or lower < 0:
			print("[sole-probe] side %d: bones missing" % side)
			continue
		var ankle: Vector3 = _bone(foot)
		# The leg's own last segment is the honest proxy for "how low does the
		# geometry go": the shin's far end. Measured from the bone rather than
		# assumed, because the rest basis Y is always 1.0 in Godot.
		var lower_tail: float = _bone(lower).distance_to(ankle)
		print("[sole-probe] %s: ankle=%s" % [_side(side), str(ankle)])
		print("[sole-probe]   shin segment (ankle - lower joint) = %.4f m" % lower_tail)
		# The toe bone, when the rig has one: the sole spans from the heel
		# (below the ankle) to the toe, so the *lowest* of the two is the
		# number that decides where the shoe sits on the ground.
		var toe: int = _skel.find_bone(StringName(
			("LeftToeBase" if side == 0 else "RightToeBase")))
		if toe < 0:
			toe = _skel.find_bone(StringName(
				("LeftToes" if side == 0 else "RightToes")))
		if toe >= 0:
			var toe_pos: Vector3 = _bone(toe)
			var drop: float = ankle.y - toe_pos.y
			print("[sole-probe]   toe bone y=%.4f, %.4f m below the ankle" % [toe_pos.y, drop])
		else:
			print("[sole-probe]   no toe bone on this rig")
		print("[sole-probe]   geometry reaches ~%.4f m below the ankle" % lower_tail)


## The rest pose's ankle height above the ground plane, which is what the
## figure stands on when nothing is correcting it.
func _report_ankle_rest() -> void:
	print("[sole-probe] --- rest pose ankle heights (model world space) ---")
	for side: int in 2:
		var foot := _feet[side]
		if foot < 0:
			continue
		var rest_ankle: Vector3 = (_skel.global_transform
			* _skel.get_bone_global_rest(foot)).origin
		print("[sole-probe] %s rest ankle y = %.4f m" % [_side(side), rest_ankle.y])


## What the plant test would compute at the rest pose, and where that puts the
## geometry. This is the arithmetic behind both reported symptoms, printed so
## the two of them can be checked against one number rather than guessed at.
func _report_clearance_at_rest() -> void:
	print("[sole-probe] --- what the plant test assumes at rest ---")
	var ground_y := 0.0
	var hit: Variant = null
	if _feet[0] >= 0:
		hit = _ground_under(_bone(_feet[0]))
	if hit != null:
		ground_y = (hit as Vector3).y
	else:
		print("[sole-probe] no ground hit under the left foot; assuming y=0")
	print("[sole-probe] ground y = %.4f m" % ground_y)
	for side: int in 2:
		var foot := _feet[side]
		if foot < 0:
			continue
		var rest_ankle: Vector3 = (_skel.global_transform
			* _skel.get_bone_global_rest(foot)).origin
		var clearance: float = rest_ankle.y - ground_y - ModelFootIK.ANKLE_HEIGHT
		print(
			"[sole-probe] %s rest clearance = %.4f m  (plant_enter %.2f → %s)"
			% [
				_side(side), clearance, _plant_enter_default(),
				"plants" if clearance <= _plant_enter_default() else "does NOT plant",
			]
		)


func _bone(index: int) -> Vector3:
	return (_skel.global_transform * _skel.get_bone_global_pose(index)).origin


func _bone_rest_tail(index: int) -> float:
	var pose := _skel.get_bone_global_rest(index)
	return pose.origin.distance_to(
		_skel.global_transform.basis.inverse() * (pose * Vector3(0.0, 1.0, 0.0))
	)


func _side(side: int) -> String:
	return "left" if side == 0 else "right"


func _ground_under(from: Vector3) -> Variant:
	var space := _skel.get_world_3d().direct_space_state
	if space == null:
		return null
	var query := PhysicsRayQueryParameters3D.create(
		from + Vector3.UP * 0.25, from - Vector3.UP * 0.55, 1)
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return null
	return hit.get("position", from) as Vector3

## `plant_enter` is a per-instance export, not a constant, so it has to be
## read off a live component. A throwaway instance carries the class default,
## which is what the shipped figure uses.
func _plant_enter_default() -> float:
	if _ik != null:
		return _ik.plant_enter
	var probe := ModelFootIK.new()
	var value: float = probe.plant_enter
	probe.free()
	return value
