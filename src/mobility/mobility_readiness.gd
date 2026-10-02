extends RefCounted
class_name MobilityReadiness
## Answers one question about a map: *can tag-driven mobility run on this one?*
##
## Tag-driven mobility is an **optional capability**, not a property every map must have.
## A mod-supplied map with no annotations is a perfectly good map — it simply cannot turn
## this feature on. That distinction has to be explicit, because the failure mode of getting
## it wrong is silent and ugly: with no usable tags, every place normalises to `other`, the
## fallback ladder resolves every activity to the same bucket, and the crowd walks around
## looking plausible while meaning nothing at all. Nobody would notice in a screenshot.
##
## So a map reports its capability instead of the loader guessing:
##
##   - **enabled** — there are enough annotated places for activity patterns to mean something.
##   - **disabled** — and a reason a UI can show, e.g. "这张地图没有活动标签".
##   - **missing** — individual tags a caller asked for that no place provides. This does NOT
##     disable anything: `ActivityTag`'s fallback ladder is exactly the mechanism for that
##     case ("no restaurant here, go to a shop instead"). It is reported so the caller can log
##     a warning rather than wonder why nobody eats.
##
## Deliberately pure and map-agnostic: it takes `DestinationChooser` candidates and returns a
## dictionary, so any map source — PLATEAU, a mod's hand-made map, the island — can be asked.

## Below this many annotated (non-`other`) places there is nothing to route between.
const MIN_TAGGED_PLACES: int = 2
## With only one distinct activity, every person in the world goes to the same kind of place.
## Technically movement, but not a day made of activities.
const MIN_DISTINCT_TAGS: int = 2


## Measure a candidate set. `required_tags` is optional: pass the canonical tags your activity
## patterns actually use to have absent ones named in `missing`.
static func assess(
	candidates: Array[Dictionary],
	required_tags: Array[StringName] = []
) -> Dictionary:
	var coverage: Dictionary = {}
	var tagged: int = 0
	for candidate: Dictionary in candidates:
		var tag: StringName = StringName(candidate.get("tag", ActivityTag.OTHER))
		coverage[tag] = int(coverage.get(tag, 0)) + 1
		if tag != ActivityTag.OTHER:
			tagged += 1

	# A tag counts as usable if any place actually carries it. `other` is the absence of an
	# annotation, not an activity, so it is excluded from both counts.
	var usable_tags: Array[StringName] = []
	for key: Variant in coverage:
		var tag: StringName = key
		if tag != ActivityTag.OTHER:
			usable_tags.append(tag)
	usable_tags.sort()

	var missing: PackedStringArray = PackedStringArray()
	for tag: StringName in required_tags:
		if int(coverage.get(tag, 0)) == 0:
			missing.append(String(tag))

	var enabled: bool = true
	var reason: String = ""
	if candidates.is_empty():
		enabled = false
		reason = "地图上没有任何可选地点"
	elif tagged < MIN_TAGGED_PLACES:
		enabled = false
		reason = "地图没有活动标签：%d 个地点全部是未标注（other）" % candidates.size()
	elif usable_tags.size() < MIN_DISTINCT_TAGS:
		enabled = false
		reason = "地图只有一种活动类型（%s），无法构成有意义的行程" % String(usable_tags[0])

	return {
		"enabled": enabled,
		"reason": reason,
		"place_count": candidates.size(),
		"tagged_count": tagged,
		"coverage": coverage,
		"usable_tags": usable_tags,
		"missing": missing,
	}


## Whether the fallback ladder will have to stand in for something the caller asked for.
## `missing` being non-empty means behaviour still runs, but with substitutions.
static func will_substitute(report: Dictionary) -> bool:
	return not (report.get("missing", PackedStringArray()) as PackedStringArray).is_empty()


## One line for a boot report or a mod list. Says what is on, or why it is off.
static func describe(report: Dictionary) -> String:
	if not bool(report.get("enabled", false)):
		return "标签驱动人流：未启用（%s）" % report.get("reason", "原因不明")
	var tags: PackedStringArray = PackedStringArray()
	for tag: Variant in (report.get("usable_tags", []) as Array):
		tags.append(String(tag))
	var line: String = "标签驱动人流：启用（%d/%d 地点已标注，活动类型 %s）" % [
		int(report.get("tagged_count", 0)),
		int(report.get("place_count", 0)),
		", ".join(tags),
	]
	var missing: PackedStringArray = report.get("missing", PackedStringArray())
	if not missing.is_empty():
		line += "；缺少 %s，将按回退阶梯替代" % ", ".join(missing)
	return line
