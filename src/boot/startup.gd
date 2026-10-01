extends Node
## Application entry point (`res://src/boot/startup.tscn`, the project's main
## scene). The scene file holds only this script; every other node is assembled in
## code, which keeps the structure reviewable as a diff and verified by the
## headless smoke test.
##
## Order is explicit rather than spread across autoloads:
##   1. load mods, so a mod can register world content before generation;
##   2. build the world through the `world_builder` service;
##   3. spawn the player and the UI on top of it.
##
## Set `DSH_VALIDATE_ONLY=1` in the environment to boot, report, and quit with a
## status code instead of entering gameplay. That is the same code path the game
## uses, which is what makes it a real smoke test rather than a syntax check.

const EXIT_OK: int = 0
const EXIT_BOOT_FAILED: int = 2

@export var auto_load_mods: bool = true

var world: Node3D = null
var player: Player = null
var hud: CanvasLayer = null

var _loading: CanvasLayer = null
var _pause_menu: CanvasLayer = null


## Autoload singletons are resolved at runtime, not at parse time, so referencing
## them from this script is intentional rather than an unresolved identifier.
func _get_configuration_warnings() -> PackedStringArray:
	return PackedStringArray()


## Quick save/load live on the boot node because they are application-level
## shortcuts; the pause menu offers the same operations for discoverability.
## `SaveSystem.load_game()` restores the player itself through the deserializer the
## player registered, so nothing needs re-wiring here.
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"quick_save"):
		SaveSystem.save_game()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"quick_load"):
		SaveSystem.load_game()
		get_viewport().set_input_as_handled()


func _ready() -> void:
	var failures: Array[String] = []
	var validate_only: bool = OS.get_environment("DSH_VALIDATE_ONLY") == "1"

	if not validate_only:
		_show_loading()
		await get_tree().process_frame

	if auto_load_mods:
		ModHost.load_all()

	_register_core_services(failures)

	await _build_world(failures)
	if world == null or not failures.is_empty():
		_finish(failures, validate_only)
		return

	_spawn_player(failures)
	_spawn_vehicles(failures)
	_spawn_freecam()
	_spawn_ui(failures)

	GameState.mode = GameState.Mode.EXPLORING
	Events.world_ready.emit(world)

	await _hide_loading()
	_finish(failures, validate_only)


## Runtime assertion used by the smoke test: after the physics has settled, is the
## player actually standing on the terrain rather than falling through it? This is
## the check that proves collision generation worked, which no static inspection
## can tell you.
func _settle_and_verify() -> void:
	var query: TerrainQuery = Services.get_as(&"terrain_query", &"TerrainQuery") as TerrainQuery
	if player == null or query == null:
		printerr("[runtime] cannot verify: player or terrain query is missing")
		get_tree().quit(EXIT_BOOT_FAILED)
		return

	var start_height: float = player.global_position.y
	for _frame: int in 40:
		await get_tree().physics_frame

	var ground: float = query.height_at(player.global_position.x, player.global_position.z)
	var drift: float = player.global_position.y - start_height
	var grounded: bool = player.is_on_floor()
	print("[runtime] player settled at (%.1f, %.1f, %.1f)" % [
		player.global_position.x, player.global_position.y, player.global_position.z,
	])
	print("[runtime] terrain height here %.2f m | drift %.2f m | on_floor=%s" % [ground, drift, grounded])

	var ok: bool = true
	if not grounded:
		printerr("[runtime] FAIL: player is not on the floor after settling")
		ok = false
	if absf(player.global_position.y - ground) > 3.0:
		printerr("[runtime] FAIL: player is %.2f m from the sampled terrain height" % absf(player.global_position.y - ground))
		ok = false
	if player.global_position.y < -10.0:
		printerr("[runtime] FAIL: player fell through the world")
		ok = false

	if ok:
		print("[runtime] COLLISION AND SPAWN VERIFIED")
		get_tree().quit(EXIT_OK)
	else:
		get_tree().quit(EXIT_BOOT_FAILED)


## Services are registered by the module that owns them, so swapping a module
## means changing one registration rather than editing the boot order.
func _register_core_services(failures: Array[String]) -> void:
	if not Services.has(&"world_builder"):
		Services.register(&"world_builder", WorldBuilder.new())
	if not Services.has(&"terrain_query"):
		Services.register(&"terrain_query", TerrainQuery.new())
	if not Services.has(&"vehicle_system"):
		Services.register(&"vehicle_system", VehicleSystem.new())
	ModIntegration.publish_core_providers()

	for required: StringName in [&"world_builder", &"terrain_query"]:
		if not Services.has(required):
			failures.append("core service not registered: %s" % required)


func _build_world(failures: Array[String]) -> void:
	# A plain Node3D is the world root on purpose: everything under it is created
	# by `WorldBuilder`, so there is no scene file to keep in sync.
	world = Node3D.new()
	world.name = "World"
	add_child(world)

	var builder: Variant = Services.get_service(&"world_builder")
	if builder == null or not (builder is WorldBuilder):
		failures.append("world_builder service has an unexpected type")
		return
	var typed_builder: WorldBuilder = builder
	# Reported because world generation is the one boot stage whose cost is invisible
	# in every other readout, and the only way to tell an optimisation from a
	# regression is to print the number that changed.
	var started_at: int = Time.get_ticks_msec()
	if not typed_builder.build(world, GameState.world_seed):
		failures.append("world generation failed (see the log above)")
	print("[boot] world build: %d ms" % (Time.get_ticks_msec() - started_at))


func _spawn_player(failures: Array[String]) -> void:
	player = PlayerScene.build()
	if player == null:
		failures.append("player scene could not be built")
		return
	world.add_child(player)

	var builder: WorldBuilder = Services.get_service(&"world_builder") as WorldBuilder
	var query: TerrainQuery = Services.get_as(&"terrain_query", &"TerrainQuery") as TerrainQuery
	if builder != null and query != null:
		player.global_position = builder.find_spawn_position(query)

	GameState.set_spawn(player.global_position)
	Events.player_spawned.emit(player)
	ModIntegration.instantiate_mod_providers(player)
	ModHost.notify_player_spawn(player)


## Vehicles and the debug camera sit on top of the generated world rather than
## inside it. They are created here, not as world-builder stages, because the
## builder's contract is about terrain and placed content: either of these can be
## deleted without the island changing at all.
func _spawn_vehicles(failures: Array[String]) -> void:
	if world == null:
		return
	var system: VehicleSystem = Services.get_as(&"vehicle_system", &"VehicleSystem") as VehicleSystem
	if system == null:
		failures.append("vehicle_system service has an unexpected type")
		return
	var query: TerrainQuery = Services.get_as(&"terrain_query", &"TerrainQuery") as TerrainQuery
	system.name = "Vehicles"
	world.add_child(system)
	# Anchored on the player so the fleet is where the player already is, rather
	# than at the island centre where they may never walk.
	var anchor: Vector3 = player.global_position if player != null else Vector3.ZERO
	system.spawn_fleet(world, query, anchor)


func _spawn_freecam() -> void:
	if world == null:
		return
	var freecam := Freecam.new()
	freecam.name = "Freecam"
	# A child of the world, not of the player: it is a world-space camera, and
	# parenting it to the character would make it inherit the motion it exists to
	# escape.
	world.add_child(freecam)


func _spawn_ui(failures: Array[String]) -> void:
	hud = CanvasLayer.new()
	hud.name = "HUD"
	hud.set_script(load("res://src/ui/hud.gd"))
	add_child(hud)

	_pause_menu = CanvasLayer.new()
	_pause_menu.name = "PauseMenu"
	_pause_menu.set_script(load("res://src/ui/pause_menu.gd"))
	add_child(_pause_menu)

	if hud.get_script() == null:
		failures.append("hud script failed to attach")


func _show_loading() -> void:
	_loading = CanvasLayer.new()
	_loading.name = "LoadingScreen"
	_loading.set_script(load("res://src/ui/loading_screen.gd"))
	add_child(_loading)


func _hide_loading() -> void:
	if _loading == null:
		return
	_loading.queue_free()
	_loading = null


func _finish(failures: Array[String], validate_only: bool) -> void:
	if not failures.is_empty():
		for failure: String in failures:
			printerr("[boot] FAIL: " + failure)
		if validate_only:
			get_tree().quit(EXIT_BOOT_FAILED)
		return

	if validate_only:
		var mod_ids: PackedStringArray = ModHost.active_ids()
		print("[boot] validate-only: mods=%s services=%s nodes=%d" % [
			", ".join(mod_ids) if not mod_ids.is_empty() else "none",
			", ".join(Services.names()),
			_count_nodes(get_tree().root),
		])
		_report_world()
		print("[boot] SMOKE TEST PASSED")
		get_tree().quit(EXIT_OK)
		return

	if OS.get_environment("DSH_RUNTIME_REPORT") == "1":
		await _settle_and_verify()
		return

	print("[boot] world ready: seed=%d mods=%d" % [GameState.world_seed, ModHost.mods.size()])
	Events.notify("世界已生成 — F1 调试 · F3 自由视角 · F5 保存 · F9 读取 · Esc 菜单", Events.NotifyLevel.SUCCESS)


func _count_nodes(node: Node) -> int:
	var total: int = 1
	for child: Node in node.get_children():
		total += _count_nodes(child)
	return total


## Post-boot facts, printed only in validate-only mode. This is what makes the
## smoke test meaningful: it reports the generated world's actual numbers instead
## of just "no errors".
func _report_world() -> void:
	var query: TerrainQuery = Services.get_as(&"terrain_query", &"TerrainQuery") as TerrainQuery
	if query != null and query.is_ready():
		var range: Vector2 = query.height_range()
		print("[boot] terrain: sampled=%s height %.1f..%.1f m island_radius=%.0f m" % [
			query.is_ready(), range.x, range.y, query.island_radius,
		])
		var probe_heights: PackedStringArray = PackedStringArray()
		for offset: float in [0.0, 120.0, 260.0, 400.0]:
			probe_heights.append("%.0fm:%.1f" % [offset, query.height_at(offset, 0.0)])
		print("[boot] centre profile: " + " ".join(probe_heights))
	else:
		printerr("[boot] terrain query is not ready — heightfield was never published")

	if player != null and is_instance_valid(player):
		print("[boot] player spawn: (%.1f, %.1f, %.1f)" % [
			player.global_position.x, player.global_position.y, player.global_position.z,
		])

	if world != null:
		var scatter: Node = world.get_node_or_null("Scatter")
		if scatter != null:
			var summary: PackedStringArray = PackedStringArray()
			for child: Node in scatter.get_children():
				if child is MultiMeshInstance3D:
					var multimesh_instance: MultiMeshInstance3D = child
					summary.append("%s=%d" % [child.name, multimesh_instance.multimesh.instance_count])
				else:
					summary.append("%s=%d" % [child.name, child.get_child_count()])
			print("[boot] scatter: " + ", ".join(summary))
		else:
			printerr("[boot] no Scatter container was created")
		var landmarks: Node = world.get_node_or_null("Landmarks")
		print("[boot] landmarks placed: %d" % (landmarks.get_child_count() if landmarks != null else 0))

	var system: VehicleSystem = Services.get_as(&"vehicle_system", &"VehicleSystem") as VehicleSystem
	if system == null:
		printerr("[boot] vehicle_system service is not available")
	else:
		var fleet: Array[String] = system.describe()
		print("[boot] vehicles: %s" % ("; ".join(fleet) if not fleet.is_empty() else "none"))

	# Reported unconditionally, including the absent case: an integration that is
	# only visible when it works is an integration nobody can debug.
	print("[boot] scripting runtimes: %s" % ScriptingRuntimes.summary())
