extends RefCounted
class_name AgentRoute
## One person's resolved itinerary: a pattern, the concrete places it resolved to, and the
## legs between them.
##
## This is where "在创建或地图变更时初始化路线并缓存" happens. Two decisions shape it:
##
##   - **Destinations are resolved at creation**, because they are cheap (a weighted pick
##     over a place list) and having them early means the agent knows where it is going
##     before it starts walking.
##   - **Only the first leg's path is computed eagerly.** The remaining paths are resolved
##     on demand through the shared `RouteCache`. Computing every leg up front would be
##     thousands of path queries during world load — the exact stall the cache exists to
##     avoid — while the agent cannot use leg three until it has finished leg one anyway.
##
## Re-initialisation is explicit: the map version is remembered, and `needs_reinit()` tells
## the owner to call `configure()` again after the map changes. A route is never silently
## reused against different geometry.

var pattern: ActivityPattern = null
var map_version: String = ""

## Resolved stops, in order. Each is `{place_id, tag, position, from_position, path}`.
var _legs: Array[Dictionary] = []
var _index: int = 0
## Steps that had no candidate even on the fallback ladder, and were therefore dropped.
var _unresolved: int = 0

var _cache: RouteCache = null
## `Callable(origin: Vector3, position: Vector3) -> float`, used by `DestinationChooser` to
## rank candidates. Separate from `_path_finder` because they answer different questions:
## this one is "roughly how far", the other is "along which line". A real navigation layer
## supplies both, but conflating them into one Callable would be a type error waiting to
## happen — the first returns a float, the second a polyline.
var _distance_of: Callable = Callable()
## `Callable(from_key: String, to_key: String) -> PackedVector3Array`.
var _path_finder: Callable = Callable()
var _rng_seed: int = 0


## Resolve a pattern against a map's annotated places.
##
## `candidates` are `DestinationChooser` dictionaries. `origin` is where the person starts
## (their actual position), and `origin_key` is the *place* they start from — usually their
## home — because a path has to be keyed on two places and the person's raw position is not
## one. Without `origin_key` the first leg has no shareable key and is left unresolved, which
## is only correct when the caller drives movement itself.
##
## `seed` makes the whole itinerary reproducible, which the rest of the world already
## promises: same map, same seed, same walk.
func configure(
	activity_pattern: ActivityPattern,
	candidates: Array[Dictionary],
	cache: RouteCache,
	version: String,
	origin: Vector3,
	seed: int = 0,
	origin_key: StringName = &""
) -> void:
	pattern = activity_pattern
	_cache = cache
	map_version = version
	_rng_seed = seed
	_index = 0
	_legs.clear()
	_unresolved = 0

	if _cache != null:
		_cache.set_map_version(version)

	if pattern == null or not pattern.is_valid():
		return

	# Seeded from the map version as well as the person, so the same person on a different
	# map draws a different itinerary rather than repeating a sequence that may not fit.
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%s|%s|%d" % [map_version, pattern.id, seed])

	var previous_position: Vector3 = origin
	var previous_place: StringName = origin_key
	for step: int in pattern.length():
		var tag: StringName = pattern.tag_at(step)
		var chosen: Dictionary = DestinationChooser.choose(
			candidates, tag, previous_position, rng, previous_place, 1.6, 220.0, _distance_of
		)
		if chosen.is_empty():
			# A map can genuinely lack this kind of place. Dropping the step keeps the rest
			# of the day coherent; it is counted so the caller can report sparse data
			# instead of quietly running a shorter day than the pattern asked for.
			_unresolved += 1
			continue
		var position: Vector3 = chosen.get("position", previous_position)
		_legs.append({
			"place_id": StringName(chosen.get("id", &"")),
			"from_place_id": previous_place,
			# The tag the pattern asked for, and the tag actually satisfied. They differ
			# whenever the fallback ladder was used, and that difference is the first thing
			# worth seeing when a map's annotation is thinner than the pattern.
			"tag": tag,
			"resolved_tag": StringName(chosen.get("tag", ActivityTag.OTHER)),
			"position": position,
			"from_position": previous_position,
			# Distinguishes "no path computed yet" from "a path was computed and came back
			# empty", which is a legitimate answer for a hop the finder cannot connect.
			# Without the flag that case would retry forever.
			"path_resolved": false,
			"path": PackedVector3Array(),
		})
		previous_position = position
		previous_place = StringName(chosen.get("id", &""))

	# The first leg is resolved here so the agent can start moving immediately.
	_ensure_path(_index)


## Whether this route was built for a different map and must be resolved again.
func needs_reinit(version: String) -> bool:
	return map_version != version


func stop_count() -> int:
	return _legs.size()


func unresolved_steps() -> int:
	return _unresolved


func place_id_at(index: int) -> StringName:
	if index < 0 or index >= _legs.size():
		return &""
	return StringName(_legs[index].get("place_id", &""))


func tag_at(index: int) -> StringName:
	if index < 0 or index >= _legs.size():
		return ActivityTag.OTHER
	return StringName(_legs[index].get("tag", ActivityTag.OTHER))


## The tag that actually satisfied the step, which differs from `tag_at()` whenever the
## fallback ladder was used — "asked for food, this map has none, went to a shop".
func resolved_tag_at(index: int) -> StringName:
	if index < 0 or index >= _legs.size():
		return ActivityTag.OTHER
	return StringName(_legs[index].get("resolved_tag", ActivityTag.OTHER))


func position_at(index: int) -> Vector3:
	if index < 0 or index >= _legs.size():
		return Vector3.ZERO
	return _legs[index].get("position", Vector3.ZERO)


func current_index() -> int:
	return _index


func current_target() -> Vector3:
	return position_at(_index)


func current_tag() -> StringName:
	return tag_at(_index)


## The polyline for the current leg, computed and cached on first use.
func current_path() -> PackedVector3Array:
	_ensure_path(_index)
	if _index < 0 or _index >= _legs.size():
		return PackedVector3Array()
	return _legs[_index].get("path", PackedVector3Array())


## Move to the next stop. Returns false when the itinerary is over.
func advance() -> bool:
	if _index >= _legs.size():
		return false
	_index += 1
	# Resolve the leg being entered, not the one being left: the agent is about to need it.
	_ensure_path(_index)
	return _index < _legs.size()


func is_finished() -> bool:
	return _legs.is_empty() or _index >= _legs.size()


## Progress through the day, for scheduling and for the debug overlay.
func progress_fraction() -> float:
	if _legs.is_empty():
		return 1.0
	return clampf(float(_index) / float(_legs.size()), 0.0, 1.0)


func describe() -> String:
	return "route(%s) %d/%d stops, %d unresolved, map=%s" % [
		pattern.id if pattern != null else "(no pattern)",
		mini(_index + 1, _legs.size()), _legs.size(), _unresolved, map_version,
	]


## Fill in one leg's path, if it has not been resolved yet and there is something to compute.
func _ensure_path(index: int) -> void:
	if index < 0 or index >= _legs.size() or _cache == null:
		return
	var leg: Dictionary = _legs[index]
	if bool(leg.get("path_resolved", false)):
		return
	var from_id: String = String(leg.get("from_place_id", &""))
	var to_id: String = String(leg.get("place_id", &""))
	# Without two place ids there is nothing to key a shared path on. That only happens when
	# the caller supplied position-only candidates, in which case it drives movement itself.
	if from_id.is_empty() or to_id.is_empty():
		leg["path_resolved"] = true
		_legs[index] = leg
		return
	leg["path"] = _cache.get_or_compute(from_id, to_id, _path_computer)
	leg["path_resolved"] = true
	_legs[index] = leg


## The path computer handed to the cache. A method rather than the injected Callable itself,
## so the required signature is declared in exactly one place.
func _path_computer(from_key: String, to_key: String) -> PackedVector3Array:
	if not _path_finder.is_valid():
		return PackedVector3Array()
	var produced: Variant = _path_finder.call(from_key, to_key)
	return produced if produced is PackedVector3Array else PackedVector3Array()


## Supply the path finder: `Callable(from_key: String, to_key: String) -> PackedVector3Array`.
##
## This and `set_distance_function()` are the only two things a map layer has to provide, so
## neither this class nor the chooser ever learns that a navigation server exists — and the
## whole mobility core stays testable with a stub that returns straight lines.
func set_path_finder(finder: Callable) -> void:
	_path_finder = finder


## Supply the ranking distance: `Callable(origin: Vector3, position: Vector3) -> float`.
## Optional; euclidean distance is used when it is absent.
func set_distance_function(measure: Callable) -> void:
	_distance_of = measure


func rng_seed() -> int:
	return _rng_seed
