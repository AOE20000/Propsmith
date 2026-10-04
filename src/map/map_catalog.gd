extends Node
class_name MapCatalog
## Every map this session could run on, and which one is the default.
##
## Registered as the `maps` service. The core ships exactly one map — the demo lawn —
## and everything else arrives through the mod seam (`ModContext.add_map_source`),
## which is how the PLATEAU city is delivered: it needs a 1.9 GB dataset the repo does
## not contain, and code that only makes sense with it, so shipping it as core content
## would mean a hard dependency on data that is optional by design.
##
## ## Selector id, not save identity
##
## A map is keyed by the **selector** it was registered under, not by its own
## `map_id()`. Those are different things on purpose: `map_id()` is the *save
## identity* — for a PLATEAU map it is a fingerprint of the dataset files, so it
## changes whenever the data is re-exported — while the selector is the stable name a
## menu and an environment variable have to agree on. `DSH_MAP_SOURCE=shibuya` must
## keep meaning Shibuya after the data is refreshed.
##
## ## Mod maps are read lazily
##
## `resolve()` and `list()` re-read the mod registry on every call rather than
## caching, because mods load at a point this node cannot know about, and a cache
## would turn a registration that happened after `_ready` into a map that silently
## does not exist. There are a handful of maps; re-reading a dictionary is not a cost
## worth avoiding.
##
## ## First registration wins
##
## The same rule as every other kind, and for the same reason: two mods claiming
## `shibuya` is a real conflict, and the resolution is reported by the mod host rather
## than silently whichever registered last.

## The map a session runs when nothing was asked for: the demo lawn. It has no
## dataset dependency and no optional-extension requirement, and it is what the
## roadmap's demo work is actually about.
const DEFAULT_MAP_ID: StringName = &"playground"

## The environment variable that names a map. Empty means "the default".
const MAP_ENV: String = "DSH_MAP_SOURCE"

## The maps that ship inside the executable. A mod map is never declared here — this
## table is the whole of what "core content" means for maps.
const BUILT_IN: Dictionary = {
	&"playground": {
		"script": preload("res://src/map/playground_map_source.gd"),
		"display_name": "试玩草坪（Demo）",
	},
}


## Every map on offer: selector, display name and the owner (core or a mod id).
func list() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for id: StringName in BUILT_IN:
		var built: Dictionary = BUILT_IN[id]
		entries.append({
			"id": id,
			"display_name": String(built["display_name"]),
			"owner": "core",
		})
	var mod_maps: Dictionary = ModHost.content(&"map")
	for id: StringName in mod_maps:
		if BUILT_IN.has(id):
			continue
		var payload: Dictionary = mod_maps[id]
		entries.append({
			"id": id,
			"display_name": String(payload.get("display_name", id)),
			"owner": String(payload.get("owner", "?")),
		})
	return entries


## The source registered under `id`, or null. An unknown map is a supported answer:
## the caller decides whether that is a fatal misconfiguration or a reason to fall
## back, and it is the caller that has the context to explain which.
func resolve(id: StringName) -> MapSource:
	var built: Dictionary = BUILT_IN.get(id, {})
	if not built.is_empty():
		var source: MapSource = (built["script"] as GDScript).new() as MapSource
		_apply_identity(source, id, "core", String(built.get("content_version", "1")))
		return source
	var payload: Variant = ModHost.content(&"map").get(id, null)
	if payload == null:
		return null
	var mod_source: MapSource = (payload as Dictionary).get("source", null) as MapSource
	if mod_source == null:
		return null
	_apply_identity(
		mod_source, id,
		String((payload as Dictionary).get("owner", "mod")),
		String((payload as Dictionary).get("content_version", "1")),
	)
	return mod_source


## Hand a resolved source its declared identity.
##
## Composing happens in the source (`map_id()`), but the *parts* belong to the
## registration: the selector is the key it was registered under and the content
## version is the provider's declaration. Setting them here means a source cannot
## disagree with its own registration.
func _apply_identity(source: MapSource, id: StringName, owner: String, version: String) -> void:
	source.identity_owner = owner
	source.identity_selector = String(id)
	source.content_version = version


## What a session runs when nothing was asked for.
func default_id() -> StringName:
	return DEFAULT_MAP_ID


## The id named by the environment, or the default when it is unset or empty.
func requested_id() -> StringName:
	var requested: String = OS.get_environment(MAP_ENV).strip_edges()
	return StringName(requested) if not requested.is_empty() else DEFAULT_MAP_ID


## Resolve what the environment asked for, explaining a miss instead of swallowing it.
##
## An unknown `DSH_MAP_SOURCE` is a misconfiguration — somebody named a map this
## session does not have, most often because the mod that provides it is not loaded —
## and the wrong response is to silently run the demo map, because the player would
## then be looking at the wrong world with nothing saying why. So: say what was asked
## for, say what is on offer, *then* fall back.
func resolve_requested() -> MapSource:
	var id: StringName = requested_id()
	var source: MapSource = resolve(id)
	if source != null:
		return source
	var offered: Array[String] = []
	for entry: Dictionary in list():
		offered.append(String(entry["id"]))
	push_warning("[boot] no map '%s' (set by %s). Available: %s — using '%s'" % [
		id, MAP_ENV, ", ".join(offered), DEFAULT_MAP_ID,
	])
	return resolve(DEFAULT_MAP_ID)
