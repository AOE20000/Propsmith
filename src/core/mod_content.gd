extends RefCounted
class_name ModContent
## The merged view of everything mods have registered, keyed by kind.
##
## Split out of `ModHost` because it is the part with rules rather than the part with
## lifecycle. Three invariants live here and only here:
##
##   1. **Ordering.** Registrations are consumed in `id` order, except terrain modifiers
##      which sort by `order` first so a mod can state its layering. Every consumer that
##      wants an order asks for it; nobody re-derives it.
##   2. **First wins.** An id claimed by two mods resolves to the first registration,
##      matching the rule `ModContext` enforces inside one mod.
##   3. **Collisions are named.** `collisions()` reports every id two mods both claim,
##      with both owners, so the failure can be attached to the author who has to change
##      something. Silently letting the later mod win is the behaviour this replaced.
##
## It holds the loader's `contexts` dictionary by reference, so registrations made after
## construction are visible without any refresh call — `Dictionary` is a reference type
## in GDScript, and relying on that is what keeps this a view rather than a copy.
##
## Being constructible on its own is the point: the rules above are unit-testable without
## a running game or a populated autoload, which the previous arrangement could not be.

## Kinds a context can contribute, and the order collision reporting visits them.
const KINDS: Array[StringName] = [&"poi", &"prop", &"item", &"combat", &"terrain", &"vehicle", &"tool", &"npc", &"player_model", &"render_style", &"map"]

var _contexts: Dictionary = {}


func _init(contexts: Dictionary) -> void:
	_contexts = contexts


## Everything registered under one kind, as id -> payload. First registration wins.
func of(kind: StringName) -> Dictionary:
	var merged: Dictionary = {}
	for mod_id: String in _contexts:
		var registry: Dictionary = registry_for(_contexts[mod_id] as ModContext, kind)
		for key: Variant in registry:
			if not merged.has(key):
				merged[key] = registry[key]
	return merged


## The same registrations as a deterministically ordered array, which is how every
## consumer actually wants them.
func ordered(kind: StringName) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for payload: Variant in of(kind).values():
		if payload is Dictionary:
			entries.append(payload)
	if kind == &"terrain":
		entries.sort_custom(_terrain_order_before)
	else:
		entries.sort_custom(_id_order_before)
	return entries


## Every id two mods both claim, as
## `{kind, id, winner, loser}`. Empty is the normal case.
func collisions() -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	for kind: StringName in KINDS:
		var claimed_by: Dictionary = {}
		var reported: Dictionary = {}
		for mod_id: String in _contexts:
			var registry: Dictionary = registry_for(_contexts[mod_id] as ModContext, kind)
			for key: Variant in registry:
				var id: String = String(key)
				if not claimed_by.has(id):
					claimed_by[id] = mod_id
					continue
				# One report per id, not one per extra claimant: a mod that happens to
				# claim many taken ids gets one line each rather than a cascade.
				if reported.has(id):
					continue
				reported[id] = true
				found.append({
					"kind": kind,
					"id": id,
					"winner": claimed_by[id],
					"loser": mod_id,
				})
	return found


## The registry a kind maps to. Public so a caller cannot disagree with `of()` about
## which dictionary it is reading.
static func registry_for(context: ModContext, kind: StringName) -> Dictionary:
	match kind:
		&"poi": return context.poi_factories
		&"prop": return context.prop_factories
		&"item": return context.item_definitions
		&"combat": return context.combat_providers
		&"terrain": return context.terrain_modifiers
		&"vehicle": return context.vehicle_factories
		&"tool": return context.tools
		&"npc": return context.npc_factories
		&"player_model": return context.player_models
		&"render_style": return context.render_styles
		&"map": return context.map_sources
	return {}


static func _id_order_before(a: Dictionary, b: Dictionary) -> bool:
	return String(a.get("id", "")) < String(b.get("id", ""))


static func _terrain_order_before(a: Dictionary, b: Dictionary) -> bool:
	var order_a: int = int(a.get("order", 100))
	var order_b: int = int(b.get("order", 100))
	if order_a == order_b:
		return String(a.get("id", "")) < String(b.get("id", ""))
	return order_a < order_b
