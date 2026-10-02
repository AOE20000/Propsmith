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

## Screenshot plan: settle at the spawn, take the street-level shot, lift the
## player for the overhead shot, then — if the sandbox is available — spawn a
## few props in front of the player and capture the menu open.
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
				_place_props()
				_next_phase()
		3:
			if _phase_frames >= SETTLE_FRAMES:
				_capture("sandbox_props.png")
				_open_menu()
				_next_phase()
		4:
			if _phase_frames >= 12:
				_capture("sandbox_menu.png")
				get_tree().quit(0)


func _next_phase() -> void:
	_phase += 1
	_phase_frames = 0


## Spawn a small prop arrangement in front of the player: the sandbox's own
## content, placed through the same service the spawn menu uses. The player is
## first returned to the recorded spawn — the previous shot lifted them into
## the air, and props spawned at altitude would land somewhere out of frame.
## Two crates are then welded and a ball hangs from a rope — the P1 constraint
## tools, exercised through the same two-shot API a click would drive.
func _place_props() -> void:
	var spawner: PropSpawner = Services.get_as(&"prop_spawner", &"PropSpawner") as PropSpawner
	var store: ConstraintStore = Services.get_as(&"constraint_store", &"ConstraintStore") as ConstraintStore
	var player: Node3D = get_tree().get_first_node_in_group(&"player") as Node3D
	var query: SurfaceQuery = Services.get_as(&"surface_query", &"SurfaceQuery") as SurfaceQuery
	if spawner == null or player == null or query == null:
		print("[probe] sandbox unavailable; skipping prop arrangement")
		return
	player.global_position = GameState.spawn_position
	if "velocity" in player:
		player.set("velocity", Vector3.ZERO)
	var forward: Vector3 = -player.global_transform.basis.z
	forward.y = 0.0
	forward = forward.normalized()
	var base: Vector3 = player.global_position + forward * 3.5
	var ids: Array[StringName] = [&"crate", &"ball", &"plank", &"barrel"]
	for index: int in ids.size():
		var spot: Vector3 = base + Vector3(float(index) * 1.2 - 1.8, 0.0, 0.0)
		spot.y = query.height_at(spot.x, spot.z) + 0.8
		spawner.spawn(ids[index], spot)
	# Two citizens right in frame: the P2 proof that the crowd walks the streets.
	spawner.spawn_citizen(base + Vector3(0.6, 0.4, 1.4), 11)
	spawner.spawn_citizen(base + Vector3(-0.9, 0.4, 2.2), 12)
	# Drop a ramp behind the row for silhouette variety.
	var ramp_spot: Vector3 = base - forward * 2.0
	ramp_spot.y = query.height_at(ramp_spot.x, ramp_spot.z) + 0.6
	spawner.spawn(&"ramp", ramp_spot, PI)
	print("[probe] props placed")

	# Constraints: stack two crates side by side and weld them, then hang a ball
	# between two planks on a rope — both through the tool's two-shot API, which
	# is exactly what a click pair would do.
	if store == null:
		return
	var weld := ConstraintTool.new(&"weld", "焊接", &"weld")
	var left: Vector3 = base + Vector3(-2.4, 0.0, 0.0)
	var crate_a := spawner.spawn(&"crate", left + Vector3(0.0, 1.2, 0.0))
	var crate_b := spawner.spawn(&"crate", left + Vector3(0.0, 2.0, 0.0))
	if crate_a != null and crate_b != null:
		weld.on_primary({"collider": crate_a, "position": crate_a.global_position, "normal": Vector3.UP})
		weld.on_primary({"collider": crate_b, "position": crate_b.global_position, "normal": Vector3.DOWN})
	var rope := ConstraintTool.new(&"rope", "绳索", &"rope")
	var ball := spawner.spawn(&"ball", left + Vector3(0.0, 0.9, 0.9))
	var anchor := spawner.spawn(&"plank", left + Vector3(0.0, 2.6, 0.9))
	if ball != null and anchor != null:
		rope.on_primary({"collider": ball, "position": ball.global_position, "normal": Vector3.UP})
		rope.on_primary({"collider": anchor, "position": anchor.global_position, "normal": Vector3.DOWN})
	print("[probe] constraints placed (%s)" % store.describe())


## Open the spawn menu exactly as the key would (its own toggle logic), so the
## menu screenshot shows the real UI with real catalogue entries.
func _open_menu() -> void:
	var menu: Node = _find_node(get_tree().root, "SpawnMenu")
	if menu != null and menu.has_method("_set_open"):
		menu.call("_set_open", true)
		print("[probe] spawn menu opened")


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


func _find_node(root: Node, wanted: String) -> Node:
	if root.name == wanted:
		return root
	for child: Node in root.get_children():
		var found: Node = _find_node(child, wanted)
		if found != null:
			return found
	return null
