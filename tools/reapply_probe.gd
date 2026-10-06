extends Node
## Does calling `ModelStance.reapply()` repeatedly move the arms?
##
## `ModelClips._write_stand_target` calls `reapply()` every blended frame, and
## `_stop_clip` calls it on the way out. `reapply` re-solves the whole arm chain
## from `_applied_global`, which `invalidate_baselines` clears — so the question
## is what a solve uses as its parent frame when the parent is a bone this
## component never aims (the spine, the neck), and whether that frame is the
## rest orientation or the live pose. If it is the live pose, every call solves
## against the previous call's output.
##
## The symptom that would show is an arm angle that walks away over successive
## calls with nothing else changing. This measures exactly that: N solves, one
## bone's world direction after each.
var _skel: Skeleton3D
var _stance: ModelStance
var _elbow: int = -1
var _f: int = 0

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
	_stance = m.get_node_or_null("Stance") as ModelStance
	_elbow = _skel.find_bone(&"LeftLowerArm")
	# Mute the stance so only our explicit reapply() calls write, then stop the
	# clips so nothing else touches the arms: the measurement is reapply alone.
	_stance.set_process(false)
	var clips := m.get_node_or_null("Clips") as ModelClips
	if clips != null:
		clips.set_process(false)

func _process(_d: float) -> void:
	if _elbow < 0 or _stance == null: return
	_f += 1
	if _f < 30: return
	if _f == 30:
		print("[re] start elbow dir %s" % str(_dir()))
	for i: int in 30:
		_stance.reapply()
		if i == 0 or i == 9 or i == 29:
			print("[re] after %2d extra reapply calls: %s" % [i + 1, str(_dir())])
	_f = 0
	get_tree().quit(0)

## The elbow bone's +Y in skeleton space, which is the direction `reapply` is
## trying to set. A solve that feeds on its own output walks away from here.
func _dir() -> Vector3:
	return _skel.get_bone_global_pose(_elbow).basis.y.normalized()
