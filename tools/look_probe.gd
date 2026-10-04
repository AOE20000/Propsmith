extends Node
## Dev-only look-development probe for the demo sprint.
##
## Separate from `screenshot_probe` on purpose. That one answers "did the city
## and the sandbox boot"; this one answers "does the frame look right". It boots
## the real game, hides every CanvasLayer, parks its own camera at a handful of
## vantage points, and saves each frame to `data/screenshots/look_*`.
##
## It can also re-light the running world, and hand the frame to any registered
## render style: a shot that names a `DemoLook` preset drives `DemoLook.apply_to`,
## and one that names a style drives `RenderDirector.set_style` — the same call the
## F2 key makes. So the probe doubles as the proof that the style switch works
## without reloading the map, and as the only way to see what a screen-space pass
## actually did: a headless test cannot look at a shader.
##
## Run with:
##   godot --path . res://tools/look_probe.tscn --resolution 1600x900 --quit-after 6000
## Env: `DSH_LOOK_ONLY=look_citizen` runs one shot; `DSH_MAP_SOURCE` picks the map.

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
		# The lawn's furniture, from above the spawn looking down the walkway.
		# Shot twice from the same place on purpose: the preset switch is the other
		# half of M-B, and the only way to see whether it worked is to look at one
		# framing under two lights.
		"name": "look_path_day",
		"eye": Vector3(-1.0, 9.0, -16.0),
		"target": Vector3(2.0, 0.5, 26.0),
	},
	{
		"name": "look_path_dusk",
		"eye": Vector3(-1.0, 9.0, -16.0),
		"target": Vector3(2.0, 0.5, 26.0),
		"preset": &"dusk",
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
	{
		# The one shot that finds its own subject. Citizens are wherever their day
		# plan put them, which on the city map is nowhere near the spawn point — and
		# "do citizens actually wear the figure?" is exactly the question a fixed
		# vantage point cannot answer there. `DSH_LOOK_ONLY=look_citizen` runs just
		# this one.
		"name": "look_citizen",
		"subject": &"citizens",
		"offset": Vector3(1.2, 1.7, -3.2),
	},
	{
		# The render-style seam, photographed. The lawn vantage point is reused for
		# the day shots so the difference is the style and nothing else.
		"name": "look_style_toon_pond",
		"eye": Vector3(0.0, 6.5, 42.0),
		"target": Vector3(0.0, -0.5, 70.0),
		"style": &"toon",
	},
	{
		"name": "look_style_toon_lawn",
		"eye": Vector3(-2.0, 3.4, 10.0),
		"target": Vector3(-24.0, 1.2, -18.0),
		"style": &"toon",
	},
	{
		# Mod-registered, data-only: eight lines in `mods/render_style_demo`.
		"name": "look_style_golden",
		"eye": Vector3(0.0, 6.5, 42.0),
		"target": Vector3(0.0, -0.5, 70.0),
		"style": &"golden_hour",
	},
	{
		# Mod-registered, with the mod's own shader.
		"name": "look_style_noir",
		"eye": Vector3(-58.0, 2.2, 66.0),
		"target": Vector3(22.0, -0.6, 74.0),
		"style": &"noir",
	},
]

## 0 waiting for the world, 1 letting it settle, 2 working through the shot list.
var _stage: int = 0
var _timer: int = 0
var _index: int = 0
var _world: Node3D = null
var _camera: Camera3D = null


func _ready() -> void:
	_keep_only(OS.get_environment("DSH_LOOK_ONLY"))
	# Reuse the real boot sequence so the probe photographs what a player sees,
	# not a variant assembled for the camera.
	var packed: PackedScene = load("res://src/boot/startup.tscn")
	add_child(packed.instantiate())
	Events.world_ready.connect(_on_world_ready)


## Restrict the run to a comma-separated list of shot names.
##
## Exists because a full sweep costs a map load per probe and most iterations are
## about one framing. Unknown names are reported rather than silently ignored —
## a typo that photographs nothing is worse than a typo that says so.
func _keep_only(filter: String) -> void:
	if filter.strip_edges().is_empty():
		return
	var wanted: PackedStringArray = filter.split(",", false)
	var kept: Array[Dictionary] = []
	for shot: Dictionary in shots:
		if wanted.has(String(shot["name"])):
			kept.append(shot)
		else:
			continue
	var missing: PackedStringArray = PackedStringArray()
	for name: String in wanted:
		var found: bool = false
		for shot: Dictionary in shots:
			found = found or String(shot["name"]) == name
		if not found:
			missing.append(name)
	if not missing.is_empty():
		print("[look] DSH_LOOK_ONLY names no such shot: %s" % ", ".join(missing))
	shots = kept
	print("[look] filtered to %d shot(s)" % shots.size())


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
	# Preset first, style second: a style retunes *over* the active preset, so the
	# order here is the same order the game uses.
	if shot.has("preset"):
		_relight(StringName(shot["preset"]), shot.get("overrides", {}))
	if shot.has("style"):
		_switch_style(StringName(shot["style"]))
	if shot.has("subject"):
		_frame_subject(shot)
		return
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


## Aim at a live node in a group instead of at a coordinate — how the citizen shot
## finds its subject on a map whose crowd is scattered across six kilometres.
##
## Two things make this work in a city and not just on a lawn. The subject is the
## group member **nearest the camera**, because a citizen photographed from 400 m
## answers nothing. And the lens is pulled in along the line of sight until
## something is visible: a citizen stands next to a building, the naive offset puts
## the camera inside it, and from inside a wall back-face culling turns the world
## into sky over floor — a photograph of nothing that looks like a bug in the
## renderer. It is the same raycast a third-person camera does, for the same reason.
##
## A missing subject leaves the previous framing in place and still saves the
## frame: the point of the shot is to answer "is it there?", and a blank photograph
## answers it better than a crashed probe.
func _frame_subject(shot: Dictionary) -> bool:
	var group: StringName = StringName(shot["subject"])
	var offset: Vector3 = shot.get("offset", Vector3(1.2, 1.7, -3.2))
	var subject: Node3D = _nearest_in_group(group)
	if subject == null:
		print("[look] %s: no valid node in group '%s'" % [shot["name"], group])
		return false

	# Chest height, near enough for a person: the point is to read a face and some
	# clothing, not to frame a whole body at arm's length.
	var aim: Vector3 = subject.global_position + Vector3(0.0, 1.15, 0.0)
	var wanted: Vector3 = subject.global_position + offset
	_camera.global_position = _clear_line(wanted, aim, subject)
	_camera.look_at(aim, Vector3.UP)
	print("[look] framing %s on a '%s' at %s (%.1f m away)" % [
		shot["name"], group, subject.global_position, _camera.global_position.distance_to(subject.global_position),
	])
	return true


func _nearest_in_group(group: StringName) -> Node3D:
	var origin: Vector3 = _camera.global_position
	var best: Node3D = null
	var best_distance: float = INF
	for node: Node in get_tree().get_nodes_in_group(group):
		if not (node is Node3D) or not is_instance_valid(node):
			continue
		var candidate := node as Node3D
		var distance: float = candidate.global_position.distance_to(origin)
		if distance < best_distance:
			best_distance = distance
			best = candidate
	return best


## The offset the shot asked for, unless the world is in the way.
func _clear_line(from: Vector3, to: Vector3, subject: Node3D) -> Vector3:
	var space: PhysicsDirectSpaceState3D = _camera.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 1
	if subject is CollisionObject3D:
		var exclude: Array[RID] = [(subject as CollisionObject3D).get_rid()]
		query.exclude = exclude
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return from
	return (hit["position"] as Vector3) + (hit["normal"] as Vector3) * 0.35


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


## Hand the frame to a registered render style — literally the call the switch key
## makes, so a style that works here works in play.
func _switch_style(style_id: StringName) -> void:
	var director: RenderDirector = Services.get_as(&"render_style", &"RenderDirector") as RenderDirector
	if director == null:
		print("[look] no render style service to switch")
		return
	if director.set_style(style_id):
		print("[look] render style -> %s" % director.current_id())
	else:
		print("[look] render style '%s' was refused" % style_id)


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
