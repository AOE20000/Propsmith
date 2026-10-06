extends Node
## Photograph the figure *while it moves*, from the game's own third-person angle.
##
## `character_shot` proves the standing pose is right, and the joint probes prove
## the walking pose reads as upright from the skeleton's point of view — but the
## playtest screenshot shows a forward-pitched, arms-trailing figure, and the two
## cannot both be right. The difference between them is the camera: the probes
## measure bone angles, the screenshot is a view from behind and slightly above,
## which foreshortens a forward lean and hides a bad one behind the hair.
##
## So this drives the real game (the same boot sequence, the same components, the
## same input) and photographs the actual viewport at intervals, from the same
## place the player sees it. Several frames, because the report is that the
## problem comes and goes — one frame can be the unlucky one.
##
## Usage:
##   godot --path . tools/walk_shot.tscn --resolution 480x640 --quit-after 400

const SHOT_DIR: String = "res://data/screenshots"
## Where along the run to shoot, in seconds from the start of walking. Chosen to
## sample the stride rather than one instant: the bug is reported as "half the
## frames", so the shots have to be dense enough to catch it.
const MARKS: Array[float] = [0.6, 0.9, 1.2, 1.5, 1.8, 2.1]

var _frames: int = 0
var _next_mark: int = 0
var _started: bool = false
var _settle: int = 0
var _elapsed: float = 0.0
var _shot: int = 0
var _rig: CameraRig = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(load("res://src/boot/startup.tscn").instantiate())
	Events.world_ready.connect(_on_world)


func _on_world(_w: Node3D) -> void:
	var player := get_tree().get_first_node_in_group(&"player") as Player
	if player != null:
		_rig = player.get_node_or_null("CameraRig") as CameraRig
		if _rig != null:
			# The playtest screenshot frames the figure filling most of the
			# height, which means the camera was pulled in close — the shipped
			# `arm_length` is 5.4 m, where the figure is small and a bad pose is
			# easy to miss. Matching the report's framing is the point: the same
			# numbers read from far away are not what the player saw.
			_rig.pivot_height = 1.3
			_rig.arm_length = 2.2
	# A beat after the world is up, so the camera has settled into its
	# third-person position before anything is photographed.
	_settle = 30


func _process(delta: float) -> void:
	if _settle > 0:
		_settle -= 1
		return
	# The input has to be held every frame: `action_press` is an edge, and
	# releasing it would stop the figure mid-stride and photograph a stop blend.
	Input.action_press(&"move_forward")
	_frames += 1
	if not _started:
		_started = true
		return
	_elapsed += delta
	if _next_mark >= MARKS.size():
		Input.action_release(&"move_forward")
		get_tree().quit(0)
		return
	if _elapsed >= MARKS[_next_mark]:
		_shoot()
		_next_mark += 1


func _shoot() -> void:
	_shot += 1
	var image: Image = get_viewport().get_texture().get_image()
	if image == null:
		print("[walkshot] no viewport image at mark %d" % _next_mark)
		return
	var path := "%s/walk_%02d.png" % [SHOT_DIR, _shot]
	image.save_png(path)
	print("[walkshot] %s (t=%.2fs)" % [path, _elapsed])
