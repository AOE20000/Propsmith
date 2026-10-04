extends RefCounted
class_name ModContext
## The face of the engine that a mod is allowed to touch. Passed to every mod
## during registration so contributions go through a checked, documented seam
## instead of reaching into scene nodes by path.
##
## Every registration returns whether it was accepted, and duplicates are
## rejected rather than silently overwriting: a mod that collides with another
## mod's id gets a warning instead of a mysterious behaviour change.

## Owners, kept so unload can remove exactly what this mod added.
var _mod_id: StringName
var _registered: Dictionary = {}

## Extension registries, keyed by id.
##
## Ordering is deliberately **not** decided here. A `ModContext` can only see its own
## mod's registrations, so any order it produced would be a per-mod order masquerading
## as a global one — which is exactly the trap two helpers in this file used to be.
## The single owner of "the order registrations are consumed in" is
## `ModHost.content_ordered()`. World generation reads these dictionaries only through
## that, except for `item_definitions`, which nothing in the core consumes yet (see the
## note on `add_item_definition`).
var poi_factories: Dictionary = {}
var prop_factories: Dictionary = {}
var item_definitions: Dictionary = {}
var combat_providers: Dictionary = {}
var terrain_modifiers: Dictionary = {}
var vehicle_factories: Dictionary = {}
var tools: Dictionary = {}
var npc_factories: Dictionary = {}
var player_models: Dictionary = {}


func _init(owner_mod_id: StringName) -> void:
	_mod_id = owner_mod_id


func get_mod_id() -> StringName:
	return _mod_id


## Add a point of interest. `factory` is a Callable returning a Node3D; the world
## builder places it and registers its discovery trigger.
## Record a world-changing decision made by this mod: it is appended to the
## journal (crash-safe, autosaved) and broadcast to every connected peer in
## multiplayer. The caller applies the change locally first — the log does not
## re-apply it. Long-term persistence is the mod's own `serialize` hook: the
## journal is a broadcast/crash-recovery channel, not a second save file.
func record_decision(kind: StringName, payload: Dictionary) -> void:
	DecisionLog.record(StringName("%s/%s" % [_mod_id, kind]), payload)


## Register the applier for one of this mod's decision kinds. It will be called
## on journal replay and whenever a peer's decision of this kind arrives, so it
## must apply the payload exactly like the live path does.
func register_decision_applier(kind: StringName, applier: Callable) -> void:
	DecisionLog.register_applier(StringName("%s/%s" % [_mod_id, kind]), applier, false)


func add_poi_factory(poi_id: StringName, display_name: String, factory: Callable, weight: float = 1.0) -> bool:
	if display_name.strip_edges().is_empty():
		push_error("[mod:%s] poi '%s' needs a display name: it is what the HUD and the discovery log show" % [_mod_id, poi_id])
		return false
	return _register_delivering(poi_factories, poi_id, {
		"id": poi_id,
		"display_name": display_name,
		"factory": factory,
		"weight": weight,
		"owner": _mod_id,
	}, "poi", "factory")


## Add a spawnable prop. `factory` is a Callable building a **RigidBody3D**
## (mesh + collision + mass fully configured); the sandbox spawn menu lists it
## and the prop spawner instantiates it on demand. This used to feed the old
## terrain scatterer (a Mesh factory) — the seam kept its kind and id rules,
## and gained the consumer the sandbox provides.
func add_prop_factory(prop_id: StringName, display_name: String, factory: Callable, category: String = "misc") -> bool:
	if display_name.strip_edges().is_empty():
		push_error("[mod:%s] prop '%s' needs a display name: it is what the spawn menu shows" % [_mod_id, prop_id])
		return false
	return _register_delivering(prop_factories, prop_id, {
		"id": prop_id,
		"display_name": display_name,
		"factory": factory,
		"category": category,
		"owner": _mod_id,
	}, "prop", "factory")


## Describe a collectible.
##
## Reserved extension point: nothing in the core consumes `item_definitions` yet — the
## collection *vocabulary* (`Events.collectible_picked_up`, `GameState.mark_collected`)
## exists and is wired, but no inventory or pickup behaviour reads a definition. It is
## kept because the save format and the event bus already carry it, and it is listed as
## unimplemented in the README rather than being quietly implied to work.
func add_item_definition(item_id: StringName, definition: Dictionary) -> bool:
	var payload: Dictionary = definition.duplicate(true)
	payload["id"] = item_id
	payload["owner"] = _mod_id
	if String(payload.get("display_name", "")).strip_edges().is_empty():
		push_error("[mod:%s] item '%s' needs a display_name; every consumer of an item begins by showing one" % [_mod_id, item_id])
		return false
	return _register(item_definitions, item_id, payload, "item")


## Provide a combat implementation. `factory` is a Callable returning a Node that
## implements the `Attacker` contract, letting a mod replace or extend how damage
## is produced without touching the player script.
func add_combat_provider(provider_id: StringName, factory: Callable) -> bool:
	return _register_delivering(combat_providers, provider_id, {
		"id": provider_id,
		"factory": factory,
		"owner": _mod_id,
	}, "combat provider", "factory")


## Register a heightfield transform applied after the base noise pass, in the order
## `ModHost.content_ordered()` decides. `modifier` is
## `Callable(x: float, z: float, height: float, falloff: float) -> float`.
func add_terrain_modifier(modifier_id: StringName, modifier: Callable, order: int = 100) -> bool:
	return _register_delivering(terrain_modifiers, modifier_id, {
		"id": modifier_id,
		"modifier": modifier,
		"order": order,
		"owner": _mod_id,
	}, "terrain modifier", "modifier")


## Provide a drivable vehicle. `factory` is a Callable returning a `Vehicle`;
## the vehicle system places it and wires its seat.
func add_vehicle_factory(vehicle_id: StringName, factory: Callable) -> bool:
	return _register_delivering(vehicle_factories, vehicle_id, {
		"id": vehicle_id,
		"factory": factory,
		"owner": _mod_id,
	}, "vehicle", "factory")


## Add a tool-gun tool. The instance carries its own two-shot/instant state and
## receives clicks from either input layer (the held tool gun in play, or the
## paused build panel). The tool gun lists it with `display_name`.
func add_tool(tool: SandboxTool) -> bool:
	if not (tool is SandboxTool) or (tool as SandboxTool).tool_id == &"":
		push_error("[mod:%s] add_tool needs a SandboxTool with a non-empty tool_id" % _mod_id)
		return false
	var instance := tool as SandboxTool
	return _register(tools, instance.tool_id, {
		"id": instance.tool_id,
		"display_name": instance.display_name,
		"tool": instance,
		"owner": _mod_id,
	}, "tool")


## The callback-shaped twin of `add_tool`: same roster, same clicks, but the
## mod supplies callables instead of a class — the shape a scripted mod (and a
## quick GDScript prototype) finds easiest.
func add_tool_callbacks(tool_id: StringName, display_name: String, callbacks: Dictionary) -> bool:
	var instance := CallbackTool.new(tool_id, display_name, callbacks)
	return add_tool(instance)


## Add an NPC kind for the spawn menu. `factory` builds a CharacterBody3D —
## usually a configured `PedestrianAgent` subclass; the spawner assigns a day
## plan (or wandering) after adding it to the world.
func add_npc_factory(npc_id: StringName, display_name: String, factory: Callable, category: String = "people") -> bool:
	if display_name.strip_edges().is_empty():
		push_error("[mod:%s] npc '%s' needs a display name: it is what the spawn menu shows" % [_mod_id, npc_id])
		return false
	return _register_delivering(npc_factories, npc_id, {
		"id": npc_id,
		"display_name": display_name,
		"factory": factory,
		"category": category,
		"owner": _mod_id,
	}, "npc", "factory")


## Replace the default player humanoid. `factory` is a Callable returning a
## **Node3D** — the model root as it should stand on the player (feet at the
## origin, facing +Z; the player scene flips it to face -Z). The first
## id-ordered registration wins, exactly like every other kind, and the
## appearance panel keeps working against whatever the model exposes: its
## variant meshes, materials and bones are matched by name, and anything a
## model lacks is silently skipped rather than erroring.
func add_player_model(model_id: StringName, display_name: String, factory: Callable) -> bool:
	return _register_delivering(player_models, model_id, {
		"id": model_id,
		"display_name": display_name,
		"factory": factory,
		"owner": _mod_id,
	}, "player model", "factory")


## Resolve another mod's registered landmark without knowing which mod owns it.
##
## Currently unused by the core: it exists so a mod can build on another mod's content
## instead of hard-coding ids it hopes are there.
func find_poi_factory(poi_id: StringName) -> Dictionary:
	return poi_factories.get(poi_id, {}) as Dictionary


## Remove everything this mod registered. Called by the loader on unload.
func release_all() -> void:
	for registry_name: String in _registered:
		var registry: Dictionary = _registry_by_name(registry_name)
		for key: String in (_registered[registry_name] as Array):
			registry.erase(key)
	_registered.clear()


func _registry_by_name(registry_name: String) -> Dictionary:
	match registry_name:
		"poi": return poi_factories
		"prop": return prop_factories
		"item": return item_definitions
		"combat provider": return combat_providers
		"terrain modifier": return terrain_modifiers
		"vehicle": return vehicle_factories
		"tool": return tools
		"npc": return npc_factories
		"player model": return player_models
	return {}


## Shared registration path: reject empty ids and collisions loudly, then record
## the key so `release_all` can undo it.
func _register(registry: Dictionary, key: StringName, payload: Dictionary, kind: String) -> bool:
	if key == &"":
		push_error("[mod:%s] %s registration with an empty id" % [_mod_id, kind])
		return false
	if registry.has(key):
		var existing: Dictionary = registry[key]
		push_warning("[mod:%s] %s id '%s' already taken by mod '%s' — keeping the first" % [
			_mod_id, kind, key, existing.get("owner", "?")
		])
		return false
	registry[key] = payload
	if not _registered.has(kind):
		_registered[kind] = []
	(_registered[kind] as Array).append(String(key))
	return true


## `_register` plus a check that the payload really carries a usable Callable under
## `field`.
##
## Without this a mod can register a null factory and nothing looks wrong until world
## generation, where the failure shows up as a missing landmark or a call on a null —
## far from the line that made the mistake. A mod is code the host did not write, so the
## seam it is handed should refuse a broken contribution at the moment it is offered.
func _register_delivering(
	registry: Dictionary, key: StringName, payload: Dictionary, kind: String, field: String
) -> bool:
	var delivered: Variant = payload.get(field, null)
	if not (delivered is Callable) or not (delivered as Callable).is_valid():
		push_error("[mod:%s] %s '%s' must supply a valid Callable as '%s'" % [_mod_id, kind, key, field])
		return false
	return _register(registry, key, payload, kind)
