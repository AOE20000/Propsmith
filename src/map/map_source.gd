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


## Identity, split into two parts that answer different questions.
##
## **`map_id()` is what a save is bound to, and it is *declared*** — composed from
## the three fields below, which the registrar (the core, or the mod that owns the
## map) hands in. It is the stable answer to "which world was this save made in".
##
## **`map_fingerprint()` is what the data is, and it is *computed*** — it is NOT part
## of the identity. A fingerprint inside the identity made every re-export of a
## dataset look like a different map, and refused a save that the player had every
## right to expect would load. The fingerprint's job is narrower: at load time it is
## compared against the save's, and a difference is **a warning, not a refusal** —
## the save loads, and whatever in it no longer resolves is temporarily ignored and
## named. Declaration governs identity; computation governs difference; difference
## degrades.

## Who provides this map: the core, or the id of the mod that registered it.
var identity_owner: String = "core"

## The stable selector a session asks for (`DSH_MAP_SOURCE`, a menu). Deliberately
## not the same thing as `map_id()`: the selector must not change when the data
## changes, or every re-export of a dataset is a different map.
var identity_selector: String = ""

## The content version the provider declares, and the one thing it promises to bump
## when the *shape* of its content changes. If it is forgotten, the fingerprint
## comparison is what notices.
var content_version: String = "1"


## The declared identity a save is bound to.
func map_id() -> String:
	if identity_selector.is_empty():
		return "unknown"
	return "%s:%s@%s" % [identity_owner, identity_selector, content_version]


## A cheap, computed description of the underlying data, for drift detection only.
## Override in a source whose world comes from data that can change independently of
## the code (a city dataset, a downloadable pack). Empty means "no drift detection".
func map_fingerprint() -> String:
	return ""


## Facts for the boot report, printed in validate-only mode.
func describe() -> Dictionary:
	return {}


## Free everything this source added. The world root itself is owned by the
## caller; a source only tears down what `build` created inside it.
func teardown(world_root: Node3D) -> void:
	Events.world_teardown_started.emit()
	if is_instance_valid(world_root):
		world_root.queue_free()
