extends RefCounted
class_name PlaceTable
## Loads an exported activity table (the `activity.json` a city's exporter writes)
## into the candidate dictionaries `DestinationChooser` routes between.
##
## The table is *derived data* — produced by `tools/city_export_activity.gd` from
## the dataset, never authored by hand, and gitignored alongside the dataset it
## came from. A map without one is fine: mobility is an optional capability and
## `MobilityReadiness` will say so. CI never downloads a dataset; the tests parse
## a synthetic payload inline instead.

const DEFAULT_DATA_ROOT: String = "res://data/plateau"
const TABLE_FILE: String = "activity.json"


## Load the table for one city. Empty array when there is none — callers treat
## that as "mobility unavailable" rather than an error.
static func load_for(city: String, data_root: String = "") -> Array[Dictionary]:
	var root: String = data_root if not data_root.is_empty() else DEFAULT_DATA_ROOT
	var path: String = ProjectSettings.globalize_path(root.path_join(city).path_join(TABLE_FILE))
	if not FileAccess.file_exists(path):
		return []
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return []
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not (parsed is Dictionary):
		push_warning("PlaceTable: %s 不是有效的 JSON 对象" % path)
		return []
	return parse_payload(parsed)


## Parse a payload (or a hand-written test fixture — same shape, same rules):
## skip entries without an id, keep every tag as-is including `other`, because
## *counting* unannotated places is exactly how `MobilityReadiness` distinguishes
## a thin map from an empty one.
static func parse_payload(payload: Dictionary) -> Array[Dictionary]:
	var candidates: Array[Dictionary] = []
	var places: Variant = payload.get("places", [])
	if not (places is Array):
		return candidates
	for place: Variant in places:
		if not (place is Dictionary):
			continue
		var entry: Dictionary = place
		var id: String = String(entry.get("id", ""))
		if id.is_empty():
			continue
		var position_value: Variant = entry.get("position", null)
		if not (position_value is Array) or (position_value as Array).size() != 3:
			continue
		var values: Array = position_value
		var position := Vector3(float(values[0]), float(values[1]), float(values[2]))
		candidates.append(DestinationChooser.make_candidate(
			StringName(id), StringName(String(entry.get("tag", "other"))), position
		))
	return candidates


## The map version recorded by the exporter. Agents key their routes and their
## shared path cache on this, so a re-export (new dataset, different file count)
## invalidates every cached route the way a map change should.
static func map_version_of(payload: Dictionary) -> String:
	return String(payload.get("map_version", ""))
