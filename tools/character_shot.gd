extends Node
## Dev-only character probe: load *the model the game will actually use* on its
## own — no map, no physics, no crowd — and shoot it from a few angles, so a
## human can judge what no assertion can: whether the forged body reads as the
## intended character, and whether the procedural stance put the arms somewhere
## believable. The full-city probes (`screenshot_probe`, `appearance_probe`) are
## the loudest way to check this; this one is the fastest, because it skips the
## one-minute map build and points the camera at a character instead of a street.
##
## It deliberately goes through `PlayerScene`'s own model resolution and stance
## attachment rather than loading the .vrm by hand: the point is to photograph
## the pipeline's output, not a private reconstruction of it. If the mod setup
## breaks, this probe breaks with it — which is the feedback we want.
##
## Run with:
##   godot --path . res://tools/character_shot.tscn --resolution 720x960 --quit-after 300
##
## Add `-- --isolate` to also shoot every mesh of the model on its own. That is
## the fast way to attribute a visual artefact (a spike, a hair-thin triangle
## reaching the floor, a slab of flat colour) to the mesh that causes it, instead
## of guessing from a composite shot.

const SHOT_DIR: String = "res://data/screenshots"
const SETTLE_FRAMES: int = 20
const SHOT_GAP_FRAMES: int = 4

var _camera: Camera3D = null
var _framed_height: float = 1.7
var _shots: Array[Dictionary] = []
var _meshes: Array[MeshInstance3D] = []
var _index: int = 0
var _frames: int = 0


func _ready() -> void:
	_setup_environment()
	# Point the probe at an arbitrary asset when asked:
	#   godot --path . res://tools/character_shot.tscn -- --model=res://assets/characters/base_female.vrm
	# Without it, photograph the model the game itself would use.
	var override := ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--model="):
			override = arg.trim_prefix("--model=")
	var model: Node3D = null
	if override.is_empty():
		# A bare probe scene skips the boot sequence, and the boot sequence is what
		# loads mods. Load them here the same way (`load_all` is a full reload, so it
		# cannot double-register) — otherwise this probe would quietly photograph the
		# built-in fallback body and call it the player model, which is exactly the
		# mistake it exists to catch.
		ModHost.load_all()
		model = PlayerScene._instantiate_player_model()
	else:
		var packed: PackedScene = load(override) as PackedScene
		if packed == null:
			printerr("[shot] cannot load %s" % override)
			get_tree().quit(1)
			return
		model = packed.instantiate() as Node3D
		# An overridden asset never went through `PlayerScene`, so it missed the
		# stance. Apply the *same* rule the game applies — a model with no
		# transform clip gets the procedural stance — otherwise the shot shows a
		# T-pose that the player will never actually see.
		PlayerScene._attach_stance_if_unanimated(model)
	if model == null:
		printerr("[shot] no player model resolved (mod disabled and no Configura?)")
		get_tree().quit(1)
		return
	add_child(model)
	PlayerScene._attach_stance_if_unanimated(model)
	# Wait for the import-time skeleton rest poses to settle into the tree, then
	# frame and shoot. Framing before the first frame would measure a model that
	# has not been placed yet.
	await get_tree().process_frame
	_collect_meshes(model)
	_build_shot_plan(model)
	_place_shot(0)
	_index = 1
	print("[shot] model=%s stance=%s height=%.2fm meshes=%d" % [
		model.name,
		"yes" if model.get_node_or_null("Stance") != null else "no",
		_framed_height,
		_meshes.size(),
	])


func _collect_meshes(model: Node3D) -> void:
	_meshes.clear()
	for node: Node in model.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance != null and mesh_instance.mesh != null:
			_meshes.append(mesh_instance)


## A neutral studio: one key light, a soft fill and a bright background, so the
## screenshots show the model's own materials rather than a silhouette.
func _setup_environment() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.72, 0.75, 0.78)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.75, 0.76, 0.8)
	e.ambient_light_energy = 0.55
	env.environment = e
	add_child(env)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-42.0, 38.0, 0.0)
	key.light_energy = 0.9
	key.shadow_enabled = true
	add_child(key)

	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-18.0, -132.0, 0.0)
	fill.light_energy = 0.3
	add_child(fill)

	_camera = Camera3D.new()
	_camera.fov = 42.0
	_camera.current = true
	add_child(_camera)


## Frame the model's actual bounds — a 150 cm girl and a 180 cm adult must both
## fill the frame, and a wrong import (a model at 100× scale, or sunk into the
## floor) shows up immediately as a badly framed shot.
func _build_shot_plan(model: Node3D) -> void:
	var bounds := _combined_aabb(model)
	var centre := bounds.get_center()
	_framed_height = maxf(bounds.size.y, 0.3)

	# Author convention: the model faces +Z, so the front camera sits on +Z.
	var distance: float = _framed_height * 1.75
	var eye := centre.y + _framed_height * 0.02
	_shots = [
		_shot("character_front.png", Vector3(0.0, eye, distance), centre, null),
		_shot("character_back.png", Vector3(0.0, eye, -distance), centre, null),
		_shot(
			"character_three_quarter.png",
			Vector3(distance * 0.62, centre.y + _framed_height * 0.1, distance * 0.78),
			centre,
			null,
		),
		_shot(
			# Head and shoulders: the shot that answers "does the face read?".
			"character_face.png",
			Vector3(0.0, bounds.position.y + _framed_height * 0.88,
				maxf(_framed_height * 0.42, 0.55)),
			Vector3(centre.x, bounds.position.y + _framed_height * 0.87, centre.z),
			null,
		),
	]

	if "--isolate" not in OS.get_cmdline_user_args():
		return
	for mesh: MeshInstance3D in _meshes:
		var box := _mesh_bounds(mesh)
		if box.size.length() < 0.001:
			continue
		var box_centre := box.get_center()
		var height := maxf(box.size.y, 0.12)
		_shots.append(_shot(
			"isolate_%s.png" % mesh.name.to_snake_case(),
			box_centre + Vector3(0.0, 0.0, height * 1.9),
			box_centre,
			mesh,
		))


func _shot(file: String, pos: Vector3, look: Vector3, only: MeshInstance3D) -> Dictionary:
	return {"file": file, "pos": pos, "look": look, "only": only}


func _process(_delta: float) -> void:
	if _shots.is_empty():
		return
	_frames += 1
	if _frames < SETTLE_FRAMES:
		return
	_frames = 0
	_capture(_shots[_index - 1]["file"])
	if _index >= _shots.size():
		get_tree().quit(0)
		return
	_place_shot(_index)
	_index += 1


func _place_shot(index: int) -> void:
	var shot: Dictionary = _shots[index]
	_apply_isolation(shot["only"])
	_camera.global_position = shot["pos"]
	_camera.look_at(shot["look"], Vector3.UP)


## Hide everything but one mesh (or bring the whole model back). An artefact that
## is invisible in a composite shot is obvious the moment its mesh is alone.
func _apply_isolation(only: MeshInstance3D) -> void:
	for mesh: MeshInstance3D in _meshes:
		mesh.visible = only == null or mesh == only


func _mesh_bounds(mesh_instance: MeshInstance3D) -> AABB:
	if mesh_instance.mesh == null:
		return AABB()
	return mesh_instance.global_transform * mesh_instance.mesh.get_aabb()


## Visible world-space bounds of every mesh in the model, so an off-centre rig
## (a mesh parented to a moving bone, an accessory far off the body) still frames
## correctly.
func _combined_aabb(model: Node3D) -> AABB:
	var bounds := AABB()
	var first := true
	for node: Node in model.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null or not mesh_instance.visible:
			continue
		var box: AABB = mesh_instance.global_transform * mesh_instance.mesh.get_aabb()
		if first:
			bounds = box
			first = false
		else:
			bounds = bounds.merge(box)
	if first:
		bounds = AABB(Vector3(-0.5, 0.0, -0.5), Vector3(1.0, 1.7, 1.0))
	return bounds


func _capture(file_name: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	var image: Image = get_viewport().get_texture().get_image()
	image.save_png(ProjectSettings.globalize_path(SHOT_DIR.path_join(file_name)))
	print("[shot] saved %s (%dx%d)" % [file_name, image.get_width(), image.get_height()])
