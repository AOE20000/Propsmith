extends RefCounted
class_name ActivityPattern
## A person's day as a sequence of canonical activity tags.
##
## This is the "某人先经过公司后经过饭店" idea made concrete: behaviour is a *pattern over
## tags*, not a set of coordinates. `[home, work, food, work, home]` says "starts at home,
## works, eats, works again, goes home" and works unchanged on any map that can be
## annotated with those tags. Nothing here knows a city, a dataset or a plugin exists.
##
## Patterns are authored, not learned: a pattern is data an author or a mod can write.
## Deriving patterns from a real trajectory corpus would produce the same type — a list of
## tags — which is why this stays a plain ordered list rather than a machine-learning
## structure. Attach that later by generating patterns, not by changing this class.

## Where a person stays put and for how long, when the pattern does not say otherwise.
## Rough, deliberate: this is a prototype's sense of "a work day", not a time-use survey.
const DEFAULT_DWELL_MINUTES: Dictionary = {
	ActivityTag.HOME: 600.0,
	ActivityTag.WORK: 420.0,
	ActivityTag.FOOD: 45.0,
	ActivityTag.SHOP: 25.0,
	ActivityTag.SCHOOL: 360.0,
	ActivityTag.LEISURE: 90.0,
	ActivityTag.SERVICE: 30.0,
	ActivityTag.TRANSIT: 5.0,
	ActivityTag.OTHER: 30.0,
}

var id: StringName = &"custom"
var display_name: String = ""
## Canonical activity tags in visit order.
var steps: Array[StringName] = []
## Minutes spent at each step; aligned with `steps`. Left empty means "use the default
## for the tag".
var dwell_minutes: Array[float] = []


func _init(pattern_id: StringName = &"custom", pattern_steps: Array[StringName] = []) -> void:
	id = pattern_id
	steps = pattern_steps.duplicate()


## Build from raw labels, normalising each through `ActivityTag`. This is the entry point
## for a hand-authored pattern on a hand-annotated map: spelling and language do not have
## to match the vocabulary exactly.
static func from_tags(pattern_id: StringName, raw_tags: Array) -> ActivityPattern:
	var pattern := ActivityPattern.new(pattern_id)
	for raw: Variant in raw_tags:
		pattern.steps.append(ActivityTag.normalize(String(raw)))
	if pattern.display_name.is_empty():
		pattern.display_name = String(pattern_id)
	return pattern


func length() -> int:
	return steps.size()


func is_valid() -> bool:
	return not steps.is_empty()


func tag_at(index: int) -> StringName:
	if index < 0 or index >= steps.size():
		return ActivityTag.OTHER
	return steps[index]


func dwell_at(index: int) -> float:
	if index >= 0 and index < dwell_minutes.size():
		return dwell_minutes[index]
	return float(DEFAULT_DWELL_MINUTES.get(tag_at(index), 30.0))


## Minutes from the start of the day to the moment of leaving step `index`.
## Used to place an agent on the pattern's timeline rather than all agents starting at once.
func departure_offset_minutes(index: int) -> float:
	var total: float = 0.0
	for step: int in maxi(index, 0):
		total += dwell_at(step)
	return total


func describe() -> String:
	var parts: PackedStringArray = PackedStringArray()
	for step: StringName in steps:
		parts.append(String(step))
	return "%s: %s" % [id, " -> ".join(parts)]


## The built-in day patterns. Small and boring on purpose: a prototype needs plausible
## routines it can reason about, not a synthetic population model.
static func commute() -> ActivityPattern:
	return from_tags(&"commute", ["home", "work", "home"])


static func commute_with_lunch() -> ActivityPattern:
	return from_tags(&"commute_with_lunch", ["home", "work", "food", "work", "home"])


static func errand_run() -> ActivityPattern:
	return from_tags(&"errand_run", ["home", "shop", "food", "home"])


static func school_day() -> ActivityPattern:
	return from_tags(&"school_day", ["home", "school", "leisure", "home"])


static func evening_out() -> ActivityPattern:
	return from_tags(&"evening_out", ["home", "food", "leisure", "home"])


static func all_builtin() -> Array[ActivityPattern]:
	var out: Array[ActivityPattern] = []
	out.append(commute())
	out.append(commute_with_lunch())
	out.append(errand_run())
	out.append(school_day())
	out.append(evening_out())
	return out
