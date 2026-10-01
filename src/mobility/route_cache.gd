extends RefCounted
class_name RouteCache
## Shares computed routes between agents, and refuses to serve them across a map change.
##
## Why this exists: hundreds of agents travelling between the same few hundred annotated
## places solve the same paths over and over. Path finding is the expensive part of the
## mobility layer, and the results are identical for a given map, so they are computed once
## and shared. The path computer is injected as a `Callable` rather than called directly so
## this stays testable and map-agnostic — it never learns what a navigation mesh is.
##
## Two rules make it correct rather than merely fast:
##
##   - **`map_version` is part of every key.** A cached path is only valid for the map it
##     was computed on. Putting the version in the key means a stale path cannot be served
##     even if nobody remembers to invalidate — the caller's mistake becomes a cache miss
##     instead of an agent walking through a wall.
##   - **Changing the version also clears the table**, so memory does not grow across map
##     reloads and the key check does not become an ever-growing set of dead entries.
##
## Paths are stored as `PackedVector3Array`: compact, and copied out on read. The copy is
## the price of not sharing a mutable buffer between agents — an agent that truncated a
## shared path would corrupt every other agent travelling the same route.

## The map the cache is currently valid for. Set through `set_map_version()`.
var map_version: String = ""
## Upper bound on distinct routes held. Reached only on a large map with many OD pairs.
var max_entries: int = 4096

var _paths: Dictionary = {}
## Bumped whenever a lookup is answered from the cache; exposed for diagnostics.
var hits: int = 0
## Bumped whenever a lookup had to compute.
var misses: int = 0
var evictions: int = 0


## Point the cache at a map. Returns whether the version actually changed, and clears
## everything when it did — a version bump means the geometry moved, so no path survives.
func set_map_version(version: String) -> bool:
	if version == map_version:
		return false
	map_version = version
	invalidate_all()
	return true


## The cached path between two places, computing it exactly once.
##
## `from_key` and `to_key` are any stable identifiers (place ids, node ids, keys into the
## road graph). `compute` is `Callable(from_key, to_key) -> Array[Vector3] | PackedVector3Array`.
##
## An empty result is deliberately **not** cached. An empty path usually means the query ran
## before the navigation data was ready, and poisoning the cache with that would make the
## failure permanent for the session instead of costing one retry.
func get_or_compute(from_key: String, to_key: String, compute: Callable) -> PackedVector3Array:
	var path: PackedVector3Array = PackedVector3Array()
	if from_key.is_empty() or to_key.is_empty():
		return path
	if from_key == to_key:
		# Same place: no travel, and no reason to ask the path computer.
		return path

	var key: String = _key(from_key, to_key)
	if _paths.has(key):
		hits += 1
		return _paths[key]

	misses += 1
	if not compute.is_valid():
		return path
	var produced: Variant = compute.call(from_key, to_key)
	if produced is PackedVector3Array:
		path = produced
	elif produced is Array:
		path = PackedVector3Array(produced)
	else:
		push_warning("RouteCache: path computer returned %s, expected a vector array" % type_string(typeof(produced)))
		return path

	if path.is_empty():
		return path

	_paths[key] = path
	_evict_if_needed()
	return path


## Drop every path that touches `place_key`, in either direction.
##
## For the partial case: a building removed, a road closed, an annotation changed. The
## map version has not changed, but some routes are now wrong, and recomputing all of them
## would be wasteful when one place was touched.
func invalidate_touching(place_key: String) -> int:
	if place_key.is_empty():
		return 0
	var suffix: String = "|" + place_key
	var prefix: String = place_key + "|"
	var doomed: Array[String] = []
	for key: String in _paths:
		if key.begins_with(prefix) or key.ends_with(suffix):
			doomed.append(key)
	for key: String in doomed:
		_paths.erase(key)
	return doomed.size()


func invalidate_all() -> void:
	_paths.clear()


func size() -> int:
	return _paths.size()


func has(from_key: String, to_key: String) -> bool:
	return _paths.has(_key(from_key, to_key))


func describe() -> String:
	return "routes=%d hits=%d misses=%d evictions=%d map=%s" % [
		_paths.size(), hits, misses, evictions, map_version if not map_version.is_empty() else "(unset)",
	]


func _key(from_key: String, to_key: String) -> String:
	# Version first so `invalidate_touching` can still match on the "from|to" tail.
	return "%s|%s|%s" % [map_version, from_key, to_key]


## Oldest-first eviction. `Dictionary` preserves insertion order in GDScript, so the first
## key is the least recently added — good enough here, and it keeps the bound hard without
## maintaining an LRU list that would cost more than the paths do.
func _evict_if_needed() -> void:
	while _paths.size() > max_entries:
		var oldest: Variant = _paths.keys()[0]
		_paths.erase(oldest)
		evictions += 1
