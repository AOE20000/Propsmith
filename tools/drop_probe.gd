extends Node
## Where the pelvis drop actually goes, read in one place.
##
## The pose probe found the figure's hips sit at 0.874 m whether
## `max_pelvis_drop` is 0.12 or 0 — so a drop of up to 0.1185 m was being
## computed and not moving the body. This checks the three places a drop could
## be lost, in order:
##
##   1. `_pelvis_current` never grows → the shortfall never reaches the ceiling.
##   2. It grows and `_hips_written` moves, but `get_bone_pose_position(hips)`
##      does not → the write is being overwritten in the same frame.
##   3. The bone pose moves but the bone's *world* position does not → the parent
##      chain is absorbing it, i.e. the legs rearranged under a hip that stayed
##      put, which is not a pelvis drop at all.
##
## Read-only, synchronous, and it prints the discriminating numbers for all
## three so the answer does not depend on which case happens to fire.

var _skel: Skeleton3D
var _ik: ModelFootIK
var _model: Node3D
var _hips: int = -1
var _chest: int = -1
var _frame: int = 0
## The largest drop seen, and the world-space hip height at that moment.
var _worst_drop: float = 0.0
var _hips_y_at_worst: float = 0.0
var _chest_y_at_worst: float = 0.0
var _bone_pose_at_worst: Vector3 = Vector3.ZERO
var _base_at_worst: Vector3 = Vector3.ZERO
var _written_at_worst: Vector3 = Vector3.ZERO
## The lowest the hips ever got, whatever the drop was doing.
var _lowest_hips: float = INF
var _lowest_chest: float = INF


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var packed: PackedScene = load("res://src/boot/startup.tscn") as PackedScene
	add_child(packed.instantiate())
	Events.world_ready.connect(_on_world)


func _on_world(_w: Node3D) -> void:
	var player := get_tree().get_first_node_in_group(&"player") as Player
	if player == null:
		print("[drop-probe] FAIL: no player")
		get_tree().quit(1)
		return
	_model = player.get_node_or_null("PlayerModel") as Node3D
	for n: Node in _model.find_children("*", "Skeleton3D", true, false):
		_skel = n as Skeleton3D
		break
	_ik = _skel.get_node_or_null("FootIK") as ModelFootIK
	_hips = _skel.find_bone(&"Hips")
	_chest = _skel.find_bone(&"Chest")
	Input.action_press(&"move_forward")


func _process(_delta: float) -> void:
	if _skel == null or _ik == null or _hips < 0:
		return
	Input.action_press(&"move_forward")
	_frame += 1
	if _frame < 100:
		return
	var drop: float = _ik._pelvis_current.length()
	var hips_world: float = (_skel.global_transform * _skel.get_bone_global_pose(_hips)).origin.y
	var chest_world: float = (_skel.global_transform * _skel.get_bone_global_pose(_chest)).origin.y
	_lowest_hips = minf(_lowest_hips, hips_world)
	_lowest_chest = minf(_lowest_chest, chest_world)
	if drop > _worst_drop:
		_worst_drop = drop
		_hips_y_at_worst = hips_world
		_chest_y_at_worst = chest_world
		_bone_pose_at_worst = _skel.get_bone_pose_position(_hips)
		_base_at_worst = _ik._hips_base
		_written_at_worst = _ik._hips_written
	if _frame >= 400:
		_report()


func _report() -> void:
	Input.action_release(&"move_forward")
	var written_minus_base: float = (_written_at_worst - _base_at_worst).length()
	print("[drop-probe] --- pelvis drop audit over %d frames ---" % _frame)
	print("[drop-probe] worst _pelvis_current      = %.4f m (ceiling %.4f)" % [
		_worst_drop, _ik.max_pelvis_drop
	])
	print("[drop-probe] at that moment:")
	print("[drop-probe]   _hips_written - _hips_base = %.4f m  <- what the bone pose was given" % written_minus_base)
	print("[drop-probe]   bone pose y                 = %.4f" % _bone_pose_at_worst.y)
	print("[drop-probe]   base y                      = %.4f" % _base_at_worst.y)
	print("[drop-probe]   written y                   = %.4f" % _written_at_worst.y)
	print("[drop-probe]   HIPS world y                = %.4f" % _hips_y_at_worst)
	print("[drop-probe]   CHEST world y               = %.4f" % _chest_y_at_worst)
	print("[drop-probe] lowest HIPS world y  = %.4f" % _lowest_hips)
	print("[drop-probe] lowest CHEST world y = %.4f" % _lowest_chest)
	print("[drop-probe] model node y = %.4f, skeleton node y = %.4f" % [
		_model.global_position.y, _skel.global_position.y
	])
	# The verdict, from the numbers rather than from a guess.
	if _worst_drop < 0.001:
		print("[drop-probe] VERDICT: no drop was ever computed — the shortfall is zero")
	elif written_minus_base < 0.001:
		print("[drop-probe] VERDICT: the drop was computed but never written into the bone pose")
	elif _hips_y_at_worst > _base_at_worst.y - _worst_drop + 0.02:
		print("[drop-probe] VERDICT: the bone pose took the write but the world height did not follow")
	else:
		print("[drop-probe] VERDICT: the drop reached the body")
	get_tree().quit(0)
