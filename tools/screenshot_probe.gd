extends Node
## Dev-only visual probe: boot the real game in windowed mode, wait until the map
## is up and the physics has settled, then save screenshots into `data/screenshots`
## and quit. Not part of the test suite — its only job is to let a human look at
## the loaded city without playing it.
##
## Run with:
##   godot --path . res://tools/screenshot_probe.tscn --resolution 1280x720 --quit-after 2400

const SETTLE_FRAMES: int = 90
const AIRBORNE_FRAMES: int = 24
const LIFT_HEIGHT: float = 70.0
const SHOT_DIR: String = "res://data/screenshots"

## Screenshot plan: settle at the spawn, take the street-level shot, then lift the
## player into the air — the camera rig follows on its own, so the overhead shot
## travels the normal pipeline instead of fighting the rig for the transform.
var _phase: int = 0
var _phase_frames: int = 0


func _ready() -> void:
	# Reuse the real boot sequence: the probe must look at exactly what a player
	# sees, not a special-cased variant of it.
	var packed: PackedScene = load("res://src/boot/startup.tscn")
	add_child(packed.instantiate())
	Events.world_ready.connect(_on_world_ready)


func _on_world_ready(_world: Node3D) -> void:
	_phase = 1


func _process(_delta: float) -> void:
	if _phase == 0:
		return
	_phase_frames += 1
	match _phase:
		1:
			if _phase_frames >= SETTLE_FRAMES:
				_capture("shibuya_spawn.png")
				_lift_player()
				_next_phase()
		2:
			if _phase_frames >= AIRBORNE_FRAMES:
				_capture("shibuya_overhead.png")
				get_tree().quit(0)


func _next_phase() -> void:
	_phase += 1
	_phase_frames = 0


## Teleport, don't fight the camera: the rig re-acquires the player, and for a
## couple dozen frames the player is airborne long enough for one clean shot.
func _lift_player() -> void:
	var player: Node3D = get_tree().get_first_node_in_group(&"player") as Node3D
	if player == null:
		return
	player.global_position += Vector3(0.0, LIFT_HEIGHT, 0.0)
	if "velocity" in player:
		player.set("velocity", Vector3.ZERO)


func _capture(file_name: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	var image: Image = get_viewport().get_texture().get_image()
	image.save_png(ProjectSettings.globalize_path(SHOT_DIR.path_join(file_name)))
	print("[probe] saved %s (%dx%d)" % [file_name, image.get_width(), image.get_height()])
