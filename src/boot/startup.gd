extends Node
## Application entry point (`res://src/boot/startup.tscn`, the project's main
## scene). The scene file holds only this script; every other node is assembled in
## code, which keeps the structure reviewable as a diff and verified by the
## headless smoke test.
##
## Order is explicit rather than spread across autoloads:
##   1. load mods, so a mod can register world content before the map builds;
##   2. build the world through the `map_source` service;
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
		# Must run *before* `_register_core_services`: the map catalogue reads
		# mod-registered maps when the session resolves its map, and a mod loaded
		# after that would be a map that silently does not exist.
		ModHost.load_all()

	_register_core_services(failures)

	await _build_world(failures)
	if world == null or not failures.is_empty():
		_finish(failures, validate_only)
		return

	_spawn_player(failures)
	_spawn_vehicles(failures)
	_spawn_freecam()
	_spawn_sandbox(failures)
	_spawn_ui(failures)

	GameState.mode = GameState.Mode.EXPLORING
	Events.world_ready.emit(world)

	await _hide_loading()
	_finish(failures, validate_only)


## Runtime assertion used by the smoke test: after the physics has settled, is the
## player actually standing on the map rather than falling through it? This is
## the check that proves collision generation worked, which no static inspection
## can tell you.
func _settle_and_verify() -> void:
	var query: SurfaceQuery = Services.get_as(&"surface_query", &"SurfaceQuery") as SurfaceQuery
	if player == null or query == null:
		printerr("[runtime] cannot verify: player or surface query is missing")
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
	print("[runtime] surface height here %.2f m | drift %.2f m | on_floor=%s" % [ground, drift, grounded])

	var ok: bool = true
	if not grounded:
		printerr("[runtime] FAIL: player is not on the floor after settling")
		ok = false
	if player.global_position.y < ground - 3.0:
		printerr("[runtime] FAIL: player is %.2f m below the sampled surface height" % absf(player.global_position.y - ground))
		ok = false
	if player.global_position.y < -10.0:
		printerr("[runtime] FAIL: player fell through the world")
		ok = false

	if ok:
		print("[runtime] COLLISION AND SPAWN VERIFIED")
		get_tree().quit(EXIT_OK)
	else:
		get_tree().quit(EXIT_BOOT_FAILED)


## Which map the session runs on.
##
## The catalogue owns the answer: the core ships the demo lawn and mods may bring
## more (the PLATEAU city arrives that way), so the choice is "what the environment
## asked for, resolved against everything registered", and the fallback when the
## ask cannot be honoured is explained rather than silent. The switch lives in
## exactly one place — the catalogue.
func _make_map_source() -> MapSource:
	var catalog: MapCatalog = Services.get_as(&"maps", &"MapCatalog") as MapCatalog
	if catalog == null:
		push_error("[boot] the maps service is missing; cannot resolve a map")
		return PlaygroundMapSource.new()
	return catalog.resolve_requested()


## Services are registered by the module that owns them, so swapping a module
## means changing one registration rather than editing the boot order.
func _register_core_services(failures: Array[String]) -> void:
	if not Services.has(&"maps"):
		var catalog := MapCatalog.new()
		catalog.name = "MapCatalog"
		Services.register(&"maps", catalog)
		add_child(catalog)
	if not Services.has(&"map_source"):
		var source: MapSource = _make_map_source()
		if source == null:
			failures.append("no map could be resolved for this session")
		else:
			Services.register(&"map_source", source)
	if not Services.has(&"surface_query"):
		Services.register(&"surface_query", SurfaceQuery.new())
	if not Services.has(&"vehicle_system"):
		Services.register(&"vehicle_system", VehicleSystem.new())
	if not Services.has(&"prop_spawner"):
		Services.register(&"prop_spawner", PropSpawner.new())
	if not Services.has(&"constraint_store"):
		Services.register(&"constraint_store", ConstraintStore.new())
	if not Services.has(&"tool_belt"):
		var belt := ToolBelt.new()
		Services.register(&"tool_belt", belt)
		# In the tree so the belt can listen for its switch and undo keys.
		add_child(belt)
	if not Services.has(&"tool_gun"):
		var gun := ToolGun.new()
		Services.register(&"tool_gun", gun)
		add_child(gun)
	# The render director is a session-level node because it must outlive a map
	# reload: it re-applies the active style when the new world replaces the
	# environment the old one carried. Registered before the world builds so a mod
	# that picked a style during registration lands on the very first frame.
	if not Services.has(&"render_style"):
		var director := RenderDirector.new()
		director.name = "RenderDirector"
		Services.register(&"render_style", director)
		add_child(director)
	# Session-level like the render director, and for the same reason: the beds must
	# outlive a map reload, and a map declares its own sound through this seam.
	if not Services.has(&"ambience"):
		var ambience := Ambience.new()
		ambience.name = "Ambience"
		Services.register(&"ambience", ambience)
		add_child(ambience)
	if not Services.has(&"photo_mode"):
		var photo := PhotoMode.new()
		photo.name = "PhotoMode"
		Services.register(&"photo_mode", photo)
		add_child(photo)
	# The persistence node registers the sandbox section with the save system;
	# bound explicitly so it talks to exactly the services registered above.
	var persistence := SandboxPersistence.new()
	add_child(persistence)
	persistence.setup(
		Services.get_as(&"prop_spawner", &"PropSpawner") as PropSpawner,
		Services.get_as(&"constraint_store", &"ConstraintStore") as ConstraintStore,
	)
	ModIntegration.publish_core_providers()

	for required: StringName in [&"map_source", &"surface_query"]:
		if not Services.has(required):
			failures.append("core service not registered: %s" % required)


func _build_world(failures: Array[String]) -> void:
	# A plain Node3D is the world root on purpose: everything under it is created
	# by the map source, so there is no scene file to keep in sync.
	world = Node3D.new()
	world.name = "World"
	add_child(world)

	var source: Variant = Services.get_service(&"map_source")
	if source == null or not (source is MapSource):
		failures.append("map_source service has an unexpected type")
		return
	var typed_source: MapSource = source
	# The sandbox containers must exist *before* the map builds: the map source
	# spawns citizens during its own build, and they need somewhere to land.
	_bind_sandbox_containers(world, failures)
	# Reported because map loading is the one boot stage whose cost is invisible
	# in every other readout, and the only way to tell an optimisation from a
	# regression is to print the number that changed.
	var started_at: int = Time.get_ticks_msec()
	if not typed_source.build(world, GameState.world_seed):
		failures.append("map build failed (see the log above)")
	print("[boot] map build: %d ms" % (Time.get_ticks_msec() - started_at))
	# The map source owns its identity; the session state just records it, so a
	# save made from here carries the same id the save check will compare against.
	# The fingerprint is advisory — recorded so a load can notice data drift — and
	# the check that consumes it warns rather than refuses.
	GameState.map_id = typed_source.map_id()
	GameState.map_selector = typed_source.identity_selector
	GameState.map_fingerprint = typed_source.map_fingerprint()


func _spawn_player(failures: Array[String]) -> void:
	player = PlayerScene.build()
	if player == null:
		failures.append("player scene could not be built")
		return
	world.add_child(player)

	var source: Variant = Services.get_service(&"map_source")
	if source is MapSource:
		player.global_position = (source as MapSource).find_spawn_position()

	GameState.set_spawn(player.global_position)
	Events.player_spawned.emit(player)
	ModIntegration.instantiate_mod_providers(player)
	ModHost.notify_player_spawn(player)


## Vehicles and the debug camera sit on top of the loaded map rather than inside
## it. They are created here, not as map-build stages, because the map source's
## contract is about the city itself: either of these can be deleted without the
## map changing at all.
func _spawn_vehicles(failures: Array[String]) -> void:
	if world == null:
		return
	var system: VehicleSystem = Services.get_as(&"vehicle_system", &"VehicleSystem") as VehicleSystem
	if system == null:
		failures.append("vehicle_system service has an unexpected type")
		return
	var query: SurfaceQuery = Services.get_as(&"surface_query", &"SurfaceQuery") as SurfaceQuery
	system.name = "Vehicles"
	world.add_child(system)
	# Anchored on the player so the fleet is where the player already is, rather
	# than at the reference point where they may never walk.
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


## The sandbox layer: props container under the world (so teardown takes the
## props with it), the grab tool, the tool gun, and the paused build panel.
## Session-level nodes — they survive map rebuilds and rebind to the new world
## through services.
## Props and constraints containers live under the world and are bound to their
## services *before* the map builds — the map source spawns citizens during its
## own build, and they need somewhere to land.
func _bind_sandbox_containers(world: Node3D, failures: Array[String]) -> void:
	var props := Node3D.new()
	props.name = "Props"
	world.add_child(props)

	var constraints := Node3D.new()
	constraints.name = "Constraints"
	world.add_child(constraints)

	var spawner: PropSpawner = Services.get_as(&"prop_spawner", &"PropSpawner") as PropSpawner
	var store: ConstraintStore = Services.get_as(&"constraint_store", &"ConstraintStore") as ConstraintStore
	if spawner == null or store == null:
		failures.append("sandbox services missing at world bind")
		return
	spawner.setup(props)
	store.setup(constraints)


func _spawn_sandbox(failures: Array[String]) -> void:
	if world == null:
		return

	# Containers were bound before the map built (the map source spawns
	# citizens during its own build); only the session nodes are created here.
	var wrench := PhysicsWrench.new()
	wrench.name = "PhysicsWrench"
	add_child(wrench)

	var menu := SpawnMenu.new()
	menu.name = "SpawnMenu"
	add_child(menu)

	var panel := BuildingPanel.new()
	panel.name = "BuildingPanel"
	add_child(panel)

	var wardrobe := CharacterPanel.new()
	wardrobe.name = "CharacterPanel"
	add_child(wardrobe)


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

	print("[boot] world ready: map=%s mods=%d" % [GameState.map_id, ModHost.mods.size()])
	Events.notify("城市已加载 — F1 调试 · F2 画风 · F3 自由视角 · F4 时段 · P 拍照 · V 换装 · F5 保存 · F9 读取 · Esc 菜单", Events.NotifyLevel.SUCCESS)


func _count_nodes(node: Node) -> int:
	var total: int = 1
	for child: Node in node.get_children():
		total += _count_nodes(child)
	return total


## Post-boot facts, printed only in validate-only mode. This is what makes the
## smoke test meaningful: it reports the loaded map's actual numbers instead of
## just "no errors".
func _report_world() -> void:
	var query: SurfaceQuery = Services.get_as(&"surface_query", &"SurfaceQuery") as SurfaceQuery
	if query != null and query.is_ready():
		print("[boot] surface query: ready (map physics present)")
	else:
		printerr("[boot] surface query is not ready — map geometry was never published")

	var source: Variant = Services.get_service(&"map_source")
	if source is MapSource:
		var info: Dictionary = (source as MapSource).describe()
		var summary: PackedStringArray = PackedStringArray()
		for key: String in info:
			summary.append("%s=%s" % [key, str(info[key])])
		print("[boot] map: " + ", ".join(summary))

	var spawner: PropSpawner = Services.get_as(&"prop_spawner", &"PropSpawner") as PropSpawner
	if spawner != null:
		print("[boot] sandbox: %s" % spawner.describe())

	if player != null and is_instance_valid(player):
		print("[boot] player spawn: (%.1f, %.1f, %.1f)" % [
			player.global_position.x, player.global_position.y, player.global_position.z,
		])

	var system: VehicleSystem = Services.get_as(&"vehicle_system", &"VehicleSystem") as VehicleSystem
	if system == null:
		printerr("[boot] vehicle_system service is not available")
	else:
		var fleet: Array[String] = system.describe()
		print("[boot] vehicles: %s" % ("; ".join(fleet) if not fleet.is_empty() else "none"))

	# Reported unconditionally, including the absent case: an integration that is
	# only visible when it works is an integration nobody can debug.
	print("[boot] scripting runtimes: %s" % ScriptingRuntimes.summary())

	var director: RenderDirector = Services.get_as(&"render_style", &"RenderDirector") as RenderDirector
	if director == null:
		printerr("[boot] render_style service is not available")
	else:
		print("[boot] render style: %s" % director.describe())

	var ambience: Ambience = Services.get_as(&"ambience", &"Ambience") as Ambience
	if ambience == null:
		printerr("[boot] ambience service is not available")
	else:
		print("[boot] ambience: %s" % ambience.describe())
