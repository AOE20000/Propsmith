extends RefCounted
class_name ScriptBridge
## The registration API handed to a mod written in a non-GDScript language.
##
## Godot Sandbox and Lua GDExtension mods cannot reach `ModContext` directly: one
## runs inside a RISC-V VM, the other inside a Lua state, and neither can be given
## a GDScript object graph to wander through. This class is the single, narrow
## surface they *are* given — every call lands on a checked `ModContext` method, so
## a foreign-language mod is subject to exactly the same id-collision rules, owner
## tracking and unload semantics as a GDScript one.
##
## Two deliberate restrictions, both for the same reason (a scripted mod is code
## the host did not write):
##
##   - `watch()` only accepts names from `WATCHABLE`. A sandboxed mod cannot
##     subscribe to an arbitrary signal by string, so it cannot observe signals the
##     host never chose to publish.
##   - nothing here hands out a node, a service or a path. A mod registers content
##     and receives read-only queries back; it does not get to walk the tree.
##
## Instances are cheap and one-shot: `ModHost` creates one per scripted mod and
## drops it with the mod.

## Core events a scripted mod may subscribe to, with the number of arguments the
## signal carries. Kept as data so the arity check and the forwarding share a
## single source of truth.
const WATCHABLE: Dictionary = {
	"poi_discovered": 3,
	"collectible_picked_up": 2,
	"damage_applied": 2,
	"attack_started": 2,
	"attack_finished": 2,
	"combatant_died": 2,
	"player_spawned": 1,
	"player_respawned": 1,
	"world_ready": 1,
	"game_saved": 1,
	"game_loaded": 1,
	"notification_posted": 2,
	"mod_signal": 3,
}

## NotifyLevel values, re-exported so a Lua mod does not have to know the enum.
const LEVEL_INFO: int = 0
const LEVEL_SUCCESS: int = 1
const LEVEL_WARNING: int = 2

## Lifecycle hooks a scripted mod may attach to. This mirrors `ModBase`'s hook set
## minus `_on_register`, which is what the mod's own entry point already is.
##
## A scripted mod cannot override a GDScript method, so the direction is reversed:
## the foreign language registers a handler here and `ScriptedMod` forwards the
## host's hook calls into it. Keeping one mechanism means the Lua and the sandbox
## path share all of the host-side code.
##
## A plain `Array`, not a `PackedStringArray`: a GDScript constant expression cannot
## contain a `PackedStringArray(...)` call. Use `hook_list()` for the packed type.
const HOOKS: Array = ["world_generate", "world_populate", "player_spawn", "tick", "unload"]


## The hook names as a packed array, for display and joining.
static func hook_list() -> PackedStringArray:
	return PackedStringArray(HOOKS)

var _context: ModContext = null
var _runtime: StringName = &""
var _log_prefix: String = ""
## Live subscriptions, kept so `release()` can undo them. A bridge that outlives
## the mod's unload would otherwise leave trampolines pointing at a freed object.
var _connections: Array[Dictionary] = []
## hook name -> Array[Callable], the foreign side's lifecycle handlers.
var _hooks: Dictionary = {}


func _init(context: ModContext, runtime: StringName = &"") -> void:
	_context = context
	_runtime = runtime
	_log_prefix = "[%s]" % runtime if runtime != &"" else ""


func mod_id() -> String:
	return String(_context.get_mod_id()) if _context != null else ""


func runtime() -> String:
	return String(_runtime)


## Names a scripted mod is allowed to pass to `watch()`.
func watchable_events() -> PackedStringArray:
	var names: PackedStringArray = PackedStringArray()
	for key: String in WATCHABLE:
		names.append(key)
	return names


## Every registration below forwards to the matching `ModContext` extension point
## and returns whether it was accepted, so a mod can report a collision instead of
## silently doing nothing.

## Record one of this mod's decisions (journaled + broadcast to peers).
## The mod applies the change itself and keeps long-term state in its own
## save section — same contract as the GDScript side's `record_decision`.
func record_decision(kind: String, payload: Dictionary) -> void:
	_context.record_decision(StringName(kind), payload)


## Register the applier for one of this mod's decision kinds (replay + peer sync).
func register_decision_applier(kind: String, applier: Callable) -> void:
	_context.register_decision_applier(StringName(kind), applier)


func add_poi(poi_id: String, display_name: String, factory: Callable, weight: float = 1.0) -> bool:
	if _context == null:
		return false
	return _context.add_poi_factory(StringName(poi_id), display_name, factory, weight)


## Low-friction prop registration for scripted mods: the mod supplies a **Mesh**
## factory and the bridge wraps it into a rigid body (box collider fitted to the
## mesh's AABB, reasonable default mass), which is what the spawn menu and the
## prop spawner consume. A scripted mod that wants full physics control calls
## `add_prop_definition` with its own RigidBody3D factory instead.
func add_prop(prop_id: String, factory: Callable, display_name: String = "") -> bool:
	if _context == null:
		return false
	var wrapped := func() -> RigidBody3D:
		var mesh_value: Variant = factory.call()
		if not (mesh_value is Mesh):
			push_warning("[mod:%s] add_prop factory did not return a Mesh" % _context.get_mod_id())
			return null
		return ScriptBridge.rigid_body_from_mesh(mesh_value)
	return _context.add_prop_factory(
		StringName(prop_id), display_name if not display_name.is_empty() else String(prop_id), wrapped
	)


## Full-control prop registration: `factory` must build a configured RigidBody3D.
func add_prop_definition(prop_id: String, display_name: String, factory: Callable, category: String = "mod") -> bool:
	if _context == null:
		return false
	return _context.add_prop_factory(StringName(prop_id), display_name, factory, category)


## Low-friction tool registration for scripted mods: the mod supplies callbacks
## and the bridge wraps them in a `CallbackTool` — the same class shape the
## core's callback tools use, so a scripted tool rides the held gun and the
## paused build panel with zero special-casing. Callback keys (all optional):
## `on_primary(hit)`, `on_secondary(hit)`, `selected()`, `deselected()`.
func add_tool(tool_id: String, display_name: String, callbacks: Dictionary) -> bool:
	if _context == null:
		return false
	var tool := CallbackTool.new(StringName(tool_id), display_name, callbacks)
	return _context.add_tool(tool)


## Low-friction NPC registration: the mod supplies a **Mesh** for the body and
## the bridge builds a `PedestrianAgent` wearing it — day plans, wandering,
## damage and death all come for free, exactly as for the built-in citizen.
func add_npc(npc_id: String, display_name: String, mesh_factory: Callable) -> bool:
	if _context == null:
		return false
	var wrapped := func() -> CharacterBody3D:
		var mesh_value: Variant = mesh_factory.call()
		if not (mesh_value is Mesh):
			push_warning("[mod:%s] add_npc factory did not return a Mesh" % _context.get_mod_id())
			return null
		var agent := PedestrianAgent.new()
		var visual := agent.get_node_or_null("Visual") as MeshInstance3D
		if visual != null:
			visual.mesh = mesh_value
		return agent
	return _context.add_npc_factory(StringName(npc_id), display_name, wrapped)


## Replace the default player humanoid from a scripted mod: the factory returns
## the model root (Node3D). Same consumer as `ModContext.add_player_model` —
## the appearance panel and the save system keep working against the modded
## look, matched by mesh/bone name wherever the model supports it.
func add_player_model(model_id: String, display_name: String, factory: Callable) -> bool:
	if _context == null:
		return false
	return _context.add_player_model(StringName(model_id), display_name, factory)


## Wrap a Mesh into a simple rigid body: box collider fitted to the AABB with a
## sensible default mass. The lowest-friction path for a scripted mod to get a
## prop into the spawn menu without hand-rolling physics bodies.
static func rigid_body_from_mesh(mesh: Mesh) -> RigidBody3D:
	var body := RigidBody3D.new()
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Visual"
	mesh_instance.mesh = mesh
	body.add_child(mesh_instance)
	var aabb: AABB = mesh.get_aabb()
	var shape := CollisionShape3D.new()
	shape.name = "Body"
	var box := BoxShape3D.new()
	box.size = aabb.size.max(Vector3.ONE * 0.1)
	shape.shape = box
	shape.position = aabb.get_center()
	body.add_child(shape)
	body.mass = 8.0
	return body


func add_item(item_id: String, definition: Dictionary) -> bool:
	if _context == null:
		return false
	return _context.add_item_definition(StringName(item_id), definition)


func add_combat_provider(provider_id: String, factory: Callable) -> bool:
	if _context == null:
		return false
	return _context.add_combat_provider(StringName(provider_id), factory)


func add_terrain_modifier(modifier_id: String, modifier: Callable, order: int = 100) -> bool:
	if _context == null:
		return false
	return _context.add_terrain_modifier(StringName(modifier_id), modifier, order)


func add_vehicle(vehicle_id: String, factory: Callable) -> bool:
	if _context == null:
		return false
	return _context.add_vehicle_factory(StringName(vehicle_id), factory)


## Subscribe to a core event. The handler is called with the signal's arguments
## positionally, exactly like a `ModBase` override, so one signature convention
## covers signals and lifecycle hooks alike.
func watch(event_name: String, handler: Callable) -> bool:
	if _context == null or not handler.is_valid():
		return false
	if not WATCHABLE.has(event_name):
		push_warning("%s watch: '%s' is not a published event (see ScriptBridge.WATCHABLE)" % [_log_prefix, event_name])
		return false
	var signal_object: Signal = _resolve_signal(event_name)
	if signal_object.is_null():
		return false
	var trampoline: Callable = Callable()
	match int(WATCHABLE[event_name]):
		0: trampoline = _forward_0.bind(handler)
		1: trampoline = _forward_1.bind(handler)
		2: trampoline = _forward_2.bind(handler)
		3: trampoline = _forward_3.bind(handler)
	if not trampoline.is_valid():
		return false
	signal_object.connect(trampoline)
	_connections.append({"signal": signal_object, "callable": trampoline})
	return true


## Attach a lifecycle handler. Returns false for an unknown hook name, so a typo in
## a Lua or sandboxed mod is reported instead of silently never firing.
func on(hook_name: String, handler: Callable) -> bool:
	if not HOOKS.has(hook_name):
		push_warning("%s on: '%s' is not a hook (known: %s)" % [
			_log_prefix, hook_name, ", ".join(hook_list()),
		])
		return false
	if not handler.is_valid():
		push_warning("%s on: '%s' got an invalid handler" % [_log_prefix, hook_name])
		return false
	if not _hooks.has(hook_name):
		_hooks[hook_name] = []
	(_hooks[hook_name] as Array).append(handler)
	return true


func has_hook(hook_name: String) -> bool:
	return _hooks.has(hook_name) and not (_hooks[hook_name] as Array).is_empty()


func hook_names() -> PackedStringArray:
	var names: PackedStringArray = PackedStringArray()
	for key: String in _hooks:
		names.append(key)
	return names


## Call every handler registered for a hook. `args` are spread into the call, so the
## foreign handler sees the same values a GDScript override would receive.
func invoke_hook(hook_name: String, args: Array = []) -> void:
	if not _hooks.has(hook_name):
		return
	for handler: Callable in (_hooks[hook_name] as Array).duplicate():
		if handler.is_valid():
			handler.callv(args)


## Drop every subscription this bridge made. `ModHost` calls this when the owning
## mod unloads, so a reloaded mod does not fire into a stale handler.
func release() -> void:
	for entry: Dictionary in _connections:
		var signal_object: Signal = entry["signal"]
		var trampoline: Callable = entry["callable"]
		if signal_object.is_null() or not signal_object.is_connected(trampoline):
			continue
		signal_object.disconnect(trampoline)
	_connections.clear()
	_hooks.clear()


## Read-only world queries. A scripted mod can ask where the ground is without
## ever holding the map backend.

func terrain_height(world_x: float, world_z: float) -> float:
	var query: SurfaceQuery = Services.get_as(&"surface_query", &"SurfaceQuery") as SurfaceQuery
	if query == null or not query.is_ready():
		return 0.0
	return query.height_at(world_x, world_z)


func surface_kind(world_x: float, world_z: float) -> String:
	var query: SurfaceQuery = Services.get_as(&"surface_query", &"SurfaceQuery") as SurfaceQuery
	if query == null:
		return "none"
	return String(query.surface_kind(world_x, world_z))


func player_position() -> Vector3:
	# Resolved through the `player` group rather than a service: the player is a
	# node the boot sequence owns, not something the service container publishes.
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return Vector3.ZERO
	var player: Node3D = tree.get_first_node_in_group(&"player") as Node3D
	if player == null:
		return Vector3.ZERO
	return player.global_position


func notify(text: String, level: int = LEVEL_INFO) -> void:
	Events.notify(text, level)


func log(message: String) -> void:
	print("%s %s" % [_log_prefix, message])


## Names of every service this project currently exposes, so a scripted mod can
## discover capabilities instead of hard-coding them.
func service_names() -> PackedStringArray:
	return Services.names()


## Signal lookup is a match, not a dictionary of Signals: `Events` signals are
## properties, and a const dictionary cannot hold them.
func _resolve_signal(event_name: String) -> Signal:
	match event_name:
		"poi_discovered": return Events.poi_discovered
		"collectible_picked_up": return Events.collectible_picked_up
		"damage_applied": return Events.damage_applied
		"attack_started": return Events.attack_started
		"attack_finished": return Events.attack_finished
		"combatant_died": return Events.combatant_died
		"player_spawned": return Events.player_spawned
		"player_respawned": return Events.player_respawned
		"world_ready": return Events.world_ready
		"game_saved": return Events.game_saved
		"game_loaded": return Events.game_loaded
		"notification_posted": return Events.notification_posted
		"mod_signal": return Events.mod_signal
	return Signal()


## Arity-specific trampolines. `bind` appends the handler after the signal's own
## arguments, so one method per arity is what lets the handler be a plain
## positional callable on the foreign side — the same shape as a `ModBase` override,
## which means a mod author writes one convention rather than two.
func _forward_0(handler: Callable) -> void:
	handler.call()


func _forward_1(a: Variant, handler: Callable) -> void:
	handler.call(a)


func _forward_2(a: Variant, b: Variant, handler: Callable) -> void:
	handler.call(a, b)


func _forward_3(a: Variant, b: Variant, c: Variant, handler: Callable) -> void:
	handler.call(a, b, c)
