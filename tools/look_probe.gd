extends Node
## Dev-only look-development probe for the demo sprint.
##
## Separate from `screenshot_probe` on purpose. That one answers "did the city
## and the sandbox boot"; this one answers "does the frame look right". It boots
## the real game, hides every CanvasLayer, parks its own camera at a handful of
## vantage points, and saves each frame to `data/screenshots/look_*`.
##
## It can also re-light the running world: a shot that names a `DemoLook` preset
## drives `DemoLook.apply_to` before framing itself, which is exactly the call a
## day/dusk switch will make — so the probe doubles as the proof that the switch
## works without reloading the map.
##
## Run with:
##   godot --path . res://tools/look_probe.tscn --resolution 1600x900 --quit-after 6000

const SHOT_DIR: String = "res://data/screenshots"

## Long enough for the camera's exposure and the water's first waves to settle;
## the map itself is already built by the time the first shot is framed.
const SETTLE_FRAMES: int = 90
const LOOK_FRAMES: int = 18

## Vantage points in the playground map. `preset` is optional; when present the
## probe relights the world to it before framing.
var shots: Array[Dictionary] = [
	{
		"name": "look_pond_bank",
		"eye": Vector3(0.0, 6.5, 42.0),
		"target": Vector3(0.0, -0.5, 70.0),
	},
	{
		"name": "look_pond_close",
		"eye": Vector3(-58.0, 2.2, 66.0),
		"target": Vector3(22.0, -0.6, 74.0),
	},
	{
		"name": "look_lawn_rooms",
		"eye": Vector3(-2.0, 3.4, 10.0),
		"target": Vector3(-24.0, 1.2, -18.0),
	},
	{
		"name": "look_overhead",
		"eye": Vector3(0.0, 95.0, 44.0),
		"target": Vector3(0.0, 0.0, 40.0),
	},
	{
		"name": "look_pond_dusk",
		"eye": Vector3(0.0, 6.5, 42.0),
		"target": Vector3(0.0, -0.5, 70.0),
		"preset": &"dusk",
	},
	{
		# Back to daylight with one value overridden: the volumetric fog the
		# presets ship switched off. Framed like the close shot, because a low
		# grazing angle is where volumetric light shafts actually show.
		"name": "look_pond_volumetric",
		"eye": Vector3(-58.0, 2.2, 66.0),
		"target": Vector3(22.0, -0.6, 74.0),
		"preset": &"day",
		"overrides": {
			"volumetric_fog_enabled": true,
			"volumetric_fog_density": 0.02,
			"volumetric_fog_anisotropy": 0.4,
		},
	},
]

## 0 waiting for the world, 1 letting it settle, 2 working through the shot list.
var _stage: int = 0
var _timer: int = 0
var _index: int = 0
var _world: Node3D = null
var _camera: Camera3D = null


func _ready() -> void:
	# Reuse the real boot sequence so the probe photographs what a player sees,
	# not a variant assembled for the camera.
	var packed: PackedScene = load("res://src/boot/startup.tscn")
	add_child(packed.instantiate())
	Events.world_ready.connect(_on_world_ready)


func _on_world_ready(world: Node3D) -> void:
	_world = world
	_hide_ui()
	_camera = Camera3D.new()
	_camera.name = "LookProbeCamera"
	_camera.fov = 62.0
	_camera.near = 0.05
	_world.add_child(_camera)
	_camera.make_current()
	_stage = 1
	_timer = 0


func _process(_delta: float) -> void:
	if _stage == 0:
		return
	_timer += 1
	if _stage == 1:
		if _timer >= SETTLE_FRAMES:
			_stage = 2
			_timer = 0
			_apply_shot()
		return
	if _timer < LOOK_FRAMES:
		return
	_capture(String(shots[_index]["name"]))
	_index += 1
	_timer = 0
	if _index >= shots.size():
		get_tree().quit(0)
	else:
		_apply_shot()


func _apply_shot() -> void:
	var shot: Dictionary = shots[_index]
	if shot.has("preset"):
		_relight(StringName(shot["preset"]), shot.get("overrides", {}))
	_camera.global_position = shot["eye"]
	var target: Vector3 = shot["target"]
	var up: Vector3 = Vector3.UP
	# A camera pointed straight down has no valid "up" to be built from, and
	# `look_at` refuses a degenerate basis rather than guessing. Tilting the
	# reference by one axis is enough to keep the overhead shot honest.
	if absf((target - _camera.global_position).normalized().dot(up)) > 0.999:
		up = Vector3.FORWARD
	_camera.look_at(target, up)
	print("[look] framing %s" % shot["name"])


## Swap the running world's look. This is the day/dusk switch, exercised — with
## optional per-shot overrides, which is how the volumetric-fog variant is shot
## without shipping a preset that has it on.
func _relight(preset_name: StringName, overrides: Dictionary = {}) -> void:
	if _world == null:
		return
	var world_environment := _world.get_node_or_null("Environment") as WorldEnvironment
	var sun := _world.get_node_or_null("Sun") as DirectionalLight3D
	if world_environment == null or sun == null:
		print("[look] no environment in the world to relight")
		return
	if DemoLook.apply_to(world_environment.environment, sun, preset_name, overrides):
		print("[look] relit the world to '%s'%s" % [
			preset_name, " with overrides" if not overrides.is_empty() else "",
		])


## Hide every CanvasLayer: a look frame with a crosshair and a hint banner in it
## is not a look frame.
func _hide_ui() -> void:
	var stack: Array[Node] = [get_tree().root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child: Node in node.get_children():
			stack.append(child)
		if node is CanvasLayer:
			(node as CanvasLayer).visible = false


func _capture(file_name: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	var image: Image = get_viewport().get_texture().get_image()
	image.save_png(ProjectSettings.globalize_path(SHOT_DIR.path_join(file_name)) + ".png")
	print("[look] saved %s (%dx%d)" % [file_name, image.get_width(), image.get_height()])
