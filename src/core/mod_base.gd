extends RefCounted
class_name ModBase
## Base class for a content mod. A mod subclasses this, overrides the hooks it
## needs, and nothing else: the loader owns discovery, ordering, and teardown.
##
## Consumers add features by extending the *extension points* below rather than
## by editing core scripts, which is what makes the core replaceable and what
## keeps two mods from conflicting over a hard-coded node path.
##
## Contract:
##   - Hooks run on the main thread, in the order the loader resolved: dependencies
##     first, ties broken by id.
##   - **Load-time** failures are contained. A mod that cannot be scanned, parsed,
##     instantiated, registered, or started is reported and left out, while every other
##     mod loads normally. This is what makes mods additive rather than load-bearing.
##   - **Runtime** failures are not recoverable, and this comment used to claim
##     otherwise. GDScript has no exceptions, so there is nothing the loader could catch:
##     if your `_on_tick` divides by zero, the engine logs it and that call ends. What
##     *is* guaranteed is blast radius — the loader invokes each mod's hook separately,
##     so a failing mod cannot stop the hooks of the mods after it. Do not read that as
##     permission to leave a hook fragile: you get no retraction, and the mod stays
##     loaded with whatever half-finished state it left behind.
##   - Never assume another mod has run. Resolve optional collaborators through
##     `Services` and tolerate `null`.

## Unique, lowercase, stable id. Defaults to the mod's directory name.
var mod_id: StringName = &""
## Human-readable name shown in the mod list.
var display_name: String = ""
var version: String = "1.0.0"
var author: String = ""
## Mod ids that must load before this one. A missing dependency only warns, so a
## broken optional mod never blocks the game from starting.
var dependencies: PackedStringArray = PackedStringArray()

## Set by the loader; the sanctioned way to contribute content.
var context: ModContext = null


## Called once, before world generation. Register services, item types, combat
## implementations, and event listeners here.
func _on_register() -> void:
	pass


## Called after the terrain heightfield exists but before props and POIs, for
## mods that reshape or annotate the landscape.
func _on_world_generate(_world: Node3D) -> void:
	pass


## Called after core props and POIs are placed. Add scenes, lights, or logic.
func _on_world_populate(_world: Node3D) -> void:
	pass


## Called after the player instance is in the tree.
func _on_player_spawn(_player: Node3D) -> void:
	pass


## Called every frame while exploring, in mod id order.
func _on_tick(_delta: float) -> void:
	pass


## Persistence. Return any JSON-safe dictionary; it is restored through
## `deserialize` on load. Prefix keys with your mod id to stay collision-free.
func serialize() -> Dictionary:
	return {}


func deserialize(_data: Dictionary) -> void:
	pass


## Called on world teardown, in reverse load order. Release nodes and signals.
func _on_unload() -> void:
	pass


## Broadcast a signal scoped to this mod. Other mods and the core can listen on
## `Events.mod_signal` and filter by the first argument.
func emit_mod_signal(signal_name: StringName, payload: Variant = null) -> void:
	Events.mod_signal.emit(mod_id, signal_name, payload)


## Log with this mod's id as the visible prefix.
func log_message(message: String) -> void:
	print("[mod:%s] %s" % [mod_id, message])


func log_warning(message: String) -> void:
	push_warning("[mod:%s] %s" % [mod_id, message])


func _to_string() -> String:
	return "Mod(%s v%s)" % [mod_id, version]
