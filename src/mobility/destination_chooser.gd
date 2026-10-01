extends RefCounted
class_name DestinationChooser
## Picks *which* place satisfies an activity step, from a map's annotated points.
##
## The two variables the caller asked for are exactly the two inputs here:
##
##   - **tag**: only places whose normalised activity tag matches are eligible, and when
##     none match the choice walks the `ActivityTag` fallback ladder rather than failing.
##     That is what lets one behaviour layer run on a map whose annotation is thinner than
##     the one it was written against.
##   - **distance**: closer places win, by a gravity-style decay. Closer *in travel terms*
##     as soon as a navigation layer exists — `distance_of` lets the caller inject real path
##     length, and euclidean is only the cheap default.
##
## Choice is a seeded weighted sample, not argmax. Argmax would make every agent with the
## same pattern walk into the same building, which reads as a bug immediately; weighted
## sampling spreads them over the plausible options while staying reproducible for a given
## seed. Reproducibility matters here because the world is supposed to be seed-deterministic.

## Below this, the decay term is effectively flat: two places three metres apart should not
## be distinguished from each other.
const MIN_SCALE: float = 1.0


## One annotated place. `tag` is expected to be canonical already; raw labels should have
## gone through `ActivityTag.normalize` when the map was loaded.
static func make_candidate(
	place_id: StringName, tag: StringName, position: Vector3, weight: float = 1.0
) -> Dictionary:
	return {
		"id": place_id,
		"tag": tag,
		"position": position,
		"weight": maxf(weight, 0.0),
	}


## Distance-decayed attractiveness. Public so the rule is testable on its own and so a
## debug view can explain a choice instead of just showing it.
static func score(distance: float, weight: float, decay: float, scale: float) -> float:
	if weight <= 0.0:
		return 0.0
	var effective_scale: float = maxf(scale, MIN_SCALE)
	return weight / pow(1.0 + maxf(distance, 0.0) / effective_scale, maxf(decay, 0.0))


## Choose a destination for `tag`.
##
## Returns the chosen candidate dictionary, or `{}` when nothing on the fallback ladder has
## any candidate at all. An empty result is a legitimate outcome — a map can be too sparse —
## and callers must handle it rather than assume a destination always exists.
##
## `avoid_id` excludes a place, which is how a route avoids sending someone straight back
## into the building they just left.
static func choose(
	candidates: Array[Dictionary],
	tag: StringName,
	origin: Vector3,
	rng: RandomNumberGenerator,
	avoid_id: StringName = &"",
	decay: float = 1.6,
	scale: float = 220.0,
	distance_of: Callable = Callable()
) -> Dictionary:
	var eligible: Array[Dictionary] = _eligible_for(candidates, tag, avoid_id)
	if eligible.is_empty():
		return {}

	var total: float = 0.0
	var weights: PackedFloat32Array = PackedFloat32Array()
	weights.resize(eligible.size())
	for index: int in eligible.size():
		var candidate: Dictionary = eligible[index]
		var distance: float = _distance_to(candidate, origin, distance_of)
		var value: float = score(distance, float(candidate.get("weight", 1.0)), decay, scale)
		total += value
		weights[index] = value

	# Every candidate being weightless is a data problem, not a reason to return nothing:
	# fall back to uniform so the step still resolves.
	if total <= 0.0:
		return eligible[rng.randi_range(0, eligible.size() - 1)]

	var roll: float = rng.randf() * total
	var running: float = 0.0
	for index: int in eligible.size():
		running += weights[index]
		if roll <= running:
			return eligible[index]
	return eligible[eligible.size() - 1]


## The first rung of the fallback ladder that has any candidate, and everything on it.
## Exposed so a caller can report *why* a choice was made — "no `food` on this map, used
## `shop`" is the kind of thing that otherwise looks like a bug.
static func eligible_with_tag(
	candidates: Array[Dictionary],
	tag: StringName,
	avoid_id: StringName = &""
) -> Array[Dictionary]:
	return _eligible_for(candidates, tag, avoid_id)


static func _eligible_for(
	candidates: Array[Dictionary], tag: StringName, avoid_id: StringName
) -> Array[Dictionary]:
	for rung: StringName in ActivityTag.fallback_ladder(tag):
		var matches: Array[Dictionary] = []
		for candidate: Dictionary in candidates:
			if avoid_id != &"" and StringName(candidate.get("id", &"")) == avoid_id:
				continue
			if StringName(candidate.get("tag", ActivityTag.OTHER)) == rung:
				matches.append(candidate)
		if not matches.is_empty():
			return matches
	return []


static func _distance_to(
	candidate: Dictionary, origin: Vector3, distance_of: Callable
) -> float:
	var position: Vector3 = candidate.get("position", Vector3.ZERO)
	if distance_of.is_valid():
		var measured: Variant = distance_of.call(origin, position)
		if measured is float or measured is int:
			return float(measured)
	return origin.distance_to(position)
