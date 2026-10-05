extends Node
class_name FootIkProbe
## A camera parked at knee height beside the sprinting player, photographing the
## same moment twice: once with the foot IK disabled and once with it running.
##
## The numbers from `walk_probe` said the solve was not landing the foot but not
## *why* — a residual error of 10-30 cm is equally consistent with a wrong axis,
## a wrong parent frame, or a chain length that does not match the rig. This
## probe answers it with pictures instead of numbers: the same sprint, the same
## camera, the same instant, one frame apart in the toggle.
##
## It also prints the three quantities that separate those theories: where the
## ankle ended up, where the solve asked for it, and the difference.

const SHOT_TIMES: Array[float] = [1.8, 2.15, 2.5, 2.85]
const RUN_TIME: float = 4.2

var _player: Node3D = null
var _foot_ik: ModelFootIK = null
var _cam: Camera3D = null
var _elapsed: float = 0.0
var _shots: int = 0
var _running: bool = false
## True when this probe created the component (and so may remove it on exit).
var _owned: bool = false
## Planted-phase drift: how far a foot the IK fully owns travels per frame. This
## is the acceptance number for the whole feature.
var _last_ankle: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _plant_frames: int = 0
var _plant_sum: float = 0.0
var _plant_max: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# The boot is not an autoload — a probe has to instantiate it itself, the
	# way `walk_probe` does. Without this the world never exists and the window
	# stays grey.
	var packed: PackedScene = load("res://src/boot/startup.tscn") as PackedScene
	add_child(packed.instantiate())
	Events.world_ready.connect(_on_world_ready)


func _on_world_ready(_world: Node3D) -> void:
	for node: Node in get_tree().get_nodes_in_group(&"player"):
		_player = node as Node3D
		break
	if _player == null:
		print("[foot-ik-probe] no player found")
		get_tree().quit(1)
		return
	var model: Node3D = _player.get_node_or_null("PlayerModel") as Node3D
	if model == null:
		for node: Node in _player.find_children("*", "Node3D", true, false):
			var candidate := node as Node3D
			if candidate.find_child("Skeleton3D", true, false) != null:
				model = candidate
				break
	if model == null:
		print("[foot-ik-probe] no model with a skeleton")
		get_tree().quit(1)
		return
	# Reuse the attached component when the game has one; build it only if not,
	# so this probe measures the shipping behaviour either way.
	_foot_ik = model.find_child("FootIK", true, false) as ModelFootIK
	if _foot_ik == null:
		_foot_ik = ModelFootIK.new()
		_foot_ik.name = "FootIK"
		model.add_child(_foot_ik)
		_foot_ik.setup(model)
		_owned = true
	_foot_ik.set_process(false)
	_cam = Camera3D.new()
	add_child(_cam)
	_cam.make_current()
	_cam.fov = 50.0
	print("[foot-ik-probe] ready")


func _process(delta: float) -> void:
	if _player == null:
		return
	_elapsed += delta
	_frame_camera()
	_sample_drift()
	if _elapsed > 1.0 and not _running:
		_running = true
		Input.action_press(&"move_forward")
		Input.action_press(&"sprint")
	# Alternate the IK across the shot list so each state gets both gait phases,
	# and hide the UI so the legs are the only thing in frame.
	if _shots < SHOT_TIMES.size() and _elapsed >= SHOT_TIMES[_shots]:
		var ik_on: bool = _shots % 2 == 1
		_foot_ik.set_process(ik_on)
		_hide_ui()
		_shoot("foot_%s_%d" % ["on" if ik_on else "off", _shots])
		_log("ON" if ik_on else "OFF")
		print("[foot-ik-probe] shot=%d ik=%s planted=%s w=%.2f err=%.3f" % [
			_shots, ik_on, _foot_ik.is_planted(0), _foot_ik.foot_weight(0),
			_foot_ik.ik_error(0)])
		var chain: Vector3 = _foot_ik.last_reach(0)
		print("[foot-ik-probe]   chain thigh=%.3f shin=%.3f goal=%.3f (sum=%.3f)" % [
			chain.x, chain.y, chain.z, chain.x + chain.y])
		_shots += 1
	if _elapsed >= RUN_TIME:
		Input.action_release(&"move_forward")
		Input.action_release(&"sprint")
		print("[foot-ik-probe] planted drift: frames=%d mean=%.4fm max=%.4fm" % [
			_plant_frames, _plant_sum / float(maxi(_plant_frames, 1)), _plant_max])
		get_tree().quit(0)


## Park the camera beside the legs, looking slightly down the shin — close
## enough that a foot two centimetres off its pin is obvious in the picture.
func _frame_camera() -> void:
	var basis_yaw := _player.global_transform.basis
	var side: Vector3 = basis_yaw.x.normalized()
	var forward: Vector3 = -basis_yaw.z.normalized()
	var hip: Vector3 = _player.global_position + Vector3.UP * 0.55
	_cam.global_position = hip + side * 1.05 + forward * 0.75
	_cam.look_at(hip, Vector3.UP)


## The tour's start card sits exactly where the legs are; every CanvasLayer
## goes away so the frame is world and figure only. They hang off the root,
## not off the viewport's children — the earlier version only found some of them.
func _hide_ui() -> void:
	for child: Node in get_tree().root.get_children():
		if child is CanvasLayer:
			(child as CanvasLayer).visible = false


## Sample how far a fully-owned foot moves per frame. Anything above a
## millimetre or two is the slide this component exists to remove.
func _sample_drift() -> void:
	if _foot_ik == null:
		return
	for side: int in 2:
		var pos: Vector3 = _foot_ik.foot_world_pos(side)
		if _foot_ik.foot_weight(side) > 0.9:
			var step: float = pos.distance_to(_last_ankle[side])
			_plant_frames += 1
			_plant_sum += step
			_plant_max = maxf(_plant_max, step)
		_last_ankle[side] = pos


func _shoot(name: String) -> void:
	var image := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute("data/screenshots")
	image.save_png("data/screenshots/%s.png" % name)


## Print the three quantities that tell the theories apart.
func _log(label: String) -> void:
	if _foot_ik == null:
		return
	for side: int in 2:
		var chain: Dictionary = {}
		for node: Node in _player.find_children("*", "Skeleton3D", true, false):
			var skel := node as Skeleton3D
			var foot: int = skel.find_bone("LeftFoot" if side == 0 else "RightFoot")
			if foot >= 0:
				chain = {
					"ankle": (skel.global_transform * skel.get_bone_global_pose(foot)).origin,
					"ground": skel.get_bone_global_pose(foot).origin.y,
				}
				break
		if chain.is_empty():
			continue
		print("[foot-ik-probe] %s side=%d ankle=(%.3f, %.3f, %.3f) clearance=%.3f" % [
			label, side,
			(chain["ankle"] as Vector3).x, (chain["ankle"] as Vector3).y,
			(chain["ankle"] as Vector3).z, _foot_ik.last_clearance(side)])
