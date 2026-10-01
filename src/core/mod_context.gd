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

## Extension registries, keyed by id. The world builder reads these.
var poi_factories: Dictionary = {}
var prop_factories: Dictionary = {}
var item_definitions: Dictionary = {}
var combat_providers: Dictionary = {}
var terrain_modifiers: Dictionary = {}


func _init(owner_mod_id: StringName) -> void:
	_mod_id = owner_mod_id


func get_mod_id() -> StringName:
	return _mod_id


## Add a point of interest. `factory` is a Callable returning a Node3D; the world
## builder places it and registers its discovery trigger.
func add_poi_factory(poi_id: StringName, display_name: String, factory: Callable, weight: float = 1.0) -> bool:
	return _register(poi_factories, poi_id, {
		"id": poi_id,
		"display_name": display_name,
		"factory": factory,
		"weight": weight,
		"owner": _mod_id,
	}, "poi")


## Add a scattered prop (tree, rock, ruin). `factory` is a Callable returning a
## Node3D for one instance.
func add_prop_factory(prop_id: StringName, factory: Callable, density: float = 1.0, max_slope_degrees: float = 35.0) -> bool:
	return _register(prop_factories, prop_id, {
		"id": prop_id,
		"factory": factory,
		"density": density,
		"max_slope_degrees": max_slope_degrees,
		"owner": _mod_id,
	}, "prop")


## Describe a collectible. `definition` is any dictionary the pickup module
## understands; the core reads `id` and `display_name` only.
func add_item_definition(item_id: StringName, definition: Dictionary) -> bool:
	var payload: Dictionary = definition.duplicate(true)
	payload["id"] = item_id
	payload["owner"] = _mod_id
	return _register(item_definitions, item_id, payload, "item")


## Provide a combat implementation. `factory` is a Callable returning a Node that
## implements the `Attacker` contract, letting a mod replace or extend how damage
## is produced without touching the player script.
func add_combat_provider(provider_id: StringName, factory: Callable) -> bool:
	return _register(combat_providers, provider_id, {
		"id": provider_id,
		"factory": factory,
		"owner": _mod_id,
	}, "combat provider")


## Register a heightfield transform applied in deterministic id order after the
## base noise pass. `modifier` is `Callable(x: float, z: float, height: float, falloff: float) -> float`.
func add_terrain_modifier(modifier_id: StringName, modifier: Callable, order: int = 100) -> bool:
	return _register(terrain_modifiers, modifier_id, {
		"id": modifier_id,
		"modifier": modifier,
		"order": order,
		"owner": _mod_id,
	}, "terrain modifier")


## Resolve another mod's registered content without knowing which mod owns it.
func find_poi_factory(poi_id: StringName) -> Dictionary:
	return poi_factories.get(poi_id, {}) as Dictionary


func find_prop_factories() -> Array:
	var out: Array = prop_factories.values()
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
	return out


## Terrain modifiers in application order, stable across runs.
func ordered_terrain_modifiers() -> Array:
	var out: Array = terrain_modifiers.values()
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["order"]) == int(b["order"]):
			return String(a["id"]) < String(b["id"])
		return int(a["order"]) < int(b["order"])
	)
	return out


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
