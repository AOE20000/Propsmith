extends RefCounted
class_name ModIntegration
## Bridges mod-registered combat providers into the running game.
##
## Kept out of the combat classes on purpose: `Hitbox3D` and `Damageable` must not
## know that mods exist. This is the single place that reads `ModHost.content`
## and turns a registration into a live node, which is also why the combat system
## behaves identically when no mods are installed.

## Context owned by the game itself rather than by a mod, so the core can publish
## its own providers through exactly the same path a mod uses. Held as a static
## so the boot sequence can create it once and query it later.
static var core_context: ModContext = null


## Create the core context and publish the core's built-in providers through it.
## Idempotent: calling it twice does not double-register.
static func publish_core_providers() -> ModContext:
	if core_context != null:
		return core_context
	core_context = ModContext.new(&"core")
	core_context.add_combat_provider(&"melee_basic", func() -> Node:
		return BasicMeleeWeapon.new()
	)
	return core_context


## Every combat provider available this session: the core's plus every mod's.
## A mod wins a name collision only by registering first, and the collision is
## reported by `ModContext` rather than silently applying.
static func combat_providers() -> Dictionary:
	var merged: Dictionary = {}
	if core_context != null:
		merged.merge(core_context.combat_providers)
	merged.merge(ModHost.content(&"combat"))
	return merged


## Instantiate a mod-provided attacker so a mod can add a weapon without the
## player scene knowing about it. Returns provider id -> node.
static func instantiate_mod_providers(parent: Node) -> Dictionary:
	var created: Dictionary = {}
	# Resolved once, not per iteration: `combat_providers()` merges every mod's
	# registry, so looking it up inside the loop rebuilt the whole set each pass.
	var providers: Dictionary = combat_providers()
	for provider_id: String in providers:
		if provider_id == "melee_basic":
			# The core provider is instantiated by the player scene itself.
			continue
		var entry: Dictionary = providers[provider_id]
		var factory: Callable = entry.get("factory", Callable())
		if not factory.is_valid():
			continue
		var produced: Variant = factory.call()
		if not (produced is Node):
			push_warning("ModIntegration: combat provider '%s' did not return a Node" % provider_id)
			continue
		var node: Node = produced
		node.name = "ModCombat_%s" % provider_id
		parent.add_child(node)
		created[provider_id] = node
	return created
