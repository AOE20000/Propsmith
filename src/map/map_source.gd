extends RefCounted
class_name MapSource
## The seam between "the game" and "where the game happens".
##
## A map source owns everything world-shaped: loading (or generating) geometry,
## building collision, answering "where do I stand", and stating its identity so
## a save made in one city can never be loaded into another. The boot sequence
## registers one as the `map_source` service and calls `build`; it never learns
## whether the map came from a dataset, an algorithm, or a mod.
##
## The island implementation lived here once as the whole world builder. It was
## removed when the project switched to PLATEAU city maps, and it has since moved
## *out* again the other way: the only map the core ships is the demo lawn
## (`PlaygroundMapSource`), and the city arrives as a mod
## (`mods/plateau_city/`) registered through `ModContext.add_map_source`.
## `MapCatalog` is the one place that knows what is on offer, and the boot resolves
## through it — a source never learns whether the map came from a dataset, an
## algorithm, or a mod.

## Build the world under `world_root`. Returns false on failure, with the reason
## pushed to the log, so boot can abort instead of dropping the player into a
## half-built city.
func build(world_root: Node3D, seed_value: int) -> bool:
	return false


## Where the player starts. Called after `build`, so the answer may depend on
## what was actually loaded (e.g. "the street corner near the first building").
func find_spawn_position() -> Vector3:
	return Vector3(0.0, 2.0, 0.0)


## The part of the map content clusters around — for a city, where the buildings
## are dense. Mods that want to be "in the middle of things" should anchor to
## this rather than to the world origin, which is a coordinate convention, not a
## place anyone wants to stand.
var spawn_anchor: Vector3 = Vector3.ZERO


## Identity written into every save. Loading a save whose map_id differs from
## the running map is refused by `SaveSystem` — silently teleporting a player
## into a different city is the failure mode this exists to prevent.
func map_id() -> String:
	return "unknown"


## Facts for the boot report, printed in validate-only mode.
func describe() -> Dictionary:
	return {}


## Free everything this source added. The world root itself is owned by the
## caller; a source only tears down what `build` created inside it.
func teardown(world_root: Node3D) -> void:
	Events.world_teardown_started.emit()
	if is_instance_valid(world_root):
		world_root.queue_free()
