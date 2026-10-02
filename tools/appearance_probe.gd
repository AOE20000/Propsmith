extends Node
## Dev-only appearance probe: boot the real game, park a camera in front of the
## player, apply four looks through the same controller the wardrobe panel
## uses, and save one screenshot each. A human then checks what no assertion
## can: whether "taller" actually reads taller, whether the shoulder edit went
## sideways instead of outward, and whether the outfit still fits the body.
##
## Run with:
##   godot --path . res://tools/appearance_probe.tscn --quit-after 6000

const SETTLE_FRAMES: int = 90
const POSE_FRAMES: int = 30
const SHOT_DIR: String = "res://data/screenshots"

var _phase: int = 0
var _phase_frames: int = 0
var _controller: CharacterAppearanceController = null


func _ready() -> void:
	var packed: PackedScene = load("res://src/boot/startup.tscn")
	add_child(packed.instantiate())
	Events.world_ready.connect(_on_world_ready)


func _on_world_ready(_world: Node3D) -> void:
	var player: Node = get_tree().get_first_node_in_group(&"player")
	if player == null:
		get_tree().quit(1)
		return
	_controller = (player as Node).get_node_or_null("Appearance") as CharacterAppearanceController
	if _controller == null:
		printerr("[probe] no CharacterAppearanceController on the player")
		get_tree().quit(1)
		return
	_place_camera(player as Node3D)
	_phase = 1


func _process(_delta: float) -> void:
	if _phase == 0:
		return
	_phase_frames += 1
	match _phase:
		1:
			if _phase_frames >= SETTLE_FRAMES:
				_shoot("appearance_default.png", null)
				_next_phase()
		2:
			if _phase_frames >= POSE_FRAMES:
				var tall := CharacterAppearance.default_state()
				tall.record("body_height", 0.85)
				tall.record("shoulder_width", 0.6)
				tall.record("leg_length", 0.7)
				_shoot("appearance_tall.png", tall)
				_next_phase()
		3:
			if _phase_frames >= POSE_FRAMES:
				var broad := CharacterAppearance.default_state()
				broad.record("body_height", -0.85)
				broad.record("body_build", 0.9)
				broad.record("shoulder_width", 0.9)
				_shoot("appearance_short_broad.png", broad)
				_next_phase()
		4:
			if _phase_frames >= POSE_FRAMES:
				_shoot("appearance_random.png", CharacterAppearance.randomized_state())
				_next_phase()
		5:
			if _phase_frames >= POSE_FRAMES:
				get_tree().quit(0)


func _next_phase() -> void:
	_phase += 1
	_phase_frames = 0


## A dedicated camera a body-length in front of the player, slightly off-axis
## so both the silhouette and the outfit read. The game's own camera stays —
## this one just takes over as current for the captures.
func _place_camera(player: Node3D) -> void:
	var camera := Camera3D.new()
	camera.name = "AppearanceProbeCamera"
	player.add_child(camera)
	var forward: Vector3 = -player.global_transform.basis.z
	forward.y = 0.0
	forward = forward.normalized()
	camera.global_position = player.global_position + forward * 2.6 + Vector3(0.9, 1.0, 0.0)
	camera.look_at(player.global_position + Vector3(0.0, 1.0, 0.0))
	camera.current = true


func _shoot(file_name: String, state: CharacterState) -> void:
	# Fire-and-forget from `_process`: the capture lands 8 frames later, well
	# inside the POSE_FRAMES gap to the next state swap — 30 > 8 is the
	# invariant that keeps each screenshot showing only its own look.
	if state != null:
		_controller.replace_state(state)
	var frames := 0
	while frames < 8:
		await get_tree().process_frame
		frames += 1
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	var image: Image = get_viewport().get_texture().get_image()
	image.save_png(ProjectSettings.globalize_path(SHOT_DIR.path_join(file_name)))
	print("[probe] saved %s" % file_name)
