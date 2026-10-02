extends RefCounted
class_name PlaceTable
## Loads an exported place table (the TSV the city exporter writes) into the
## candidate dictionaries `DestinationChooser` routes between.
##
## The table is *derived data* — produced by `tools/city_export_activity.gd` from
## the dataset, never authored by hand, and gitignored alongside the dataset it
## came from. A map without one is fine: mobility is an optional capability and
## `MobilityReadiness` will say so. CI never downloads a dataset; the tests parse
## a synthetic payload inline instead.
##
## Format: `#`-prefixed header lines (city/lod/map_version/offset), then one
## place per line: `id\ttag\tx\ty\tz`. TSV rather than JSON on purpose — the
## full ward is ~90k places, and `JSON.parse_string` crawled on that document
## long enough to hang a boot; a split-per-line parse is milliseconds.

const DEFAULT_DATA_ROOT: String = "res://data/plateau"
const TABLE_FILE: String = "activity.tsv"


## Load the table for one city. Empty result when there is none — callers treat
## that as "mobility unavailable" rather than an error.
static func load_for(city: String, data_root: String = "") -> Dictionary:
	var root: String = data_root if not data_root.is_empty() else DEFAULT_DATA_ROOT
	var path: String = ProjectSettings.globalize_path(root.path_join(city).path_join(TABLE_FILE))
	if not FileAccess.file_exists(path):
		return {"candidates": [], "map_version": "", "offset": Vector3.ZERO}
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"candidates": [], "map_version": "", "offset": Vector3.ZERO}
	var text: String = file.get_as_text()
	file.close()
	return parse_text(text)


## Parse table text (or a hand-written fixture — same shape, same rules).
## Returns candidates plus the metadata lines: `map_version` keys route caches
## and save identity; `offset` is the whole-dataset settle the exporter used.
static func parse_text(text: String) -> Dictionary:
	var candidates: Array[Dictionary] = []
	var map_version: String = ""
	var offset := Vector3.ZERO
	for line: String in text.split("\n"):
		var trimmed: String = line.strip_edges()
		if trimmed.is_empty():
			continue
		if trimmed.begins_with("#"):
			if trimmed.begins_with("# city=") or trimmed.contains(" map_version="):
				var parts: PackedStringArray = trimmed.substr(2).split(" ")
				for part: String in parts:
					if part.begins_with("map_version="):
						map_version = part.substr("map_version=".length())
			elif trimmed.begins_with("# offset="):
				var values: PackedStringArray = trimmed.substr("# offset=".length()).split(" ")
				if values.size() == 3:
					offset = Vector3(float(values[0]), float(values[1]), float(values[2]))
			continue
		var columns: PackedStringArray = trimmed.split("\t")
		if columns.size() < 5:
			continue
		var id: String = columns[0]
		if id.is_empty():
			continue
		var position := Vector3(float(columns[2]), float(columns[3]), float(columns[4]))
		candidates.append(DestinationChooser.make_candidate(
			StringName(id), StringName(columns[1]), position
		))
	return {"candidates": candidates, "map_version": map_version, "offset": offset}


## Convenience for tests: parse a payload-shaped fixture (id/tag/position rows).
static func parse_payload(places: Array) -> Array[Dictionary]:
	var text := "# fixture\n# map_version=fixture\n"
	for place: Variant in places:
		var entry: Dictionary = place
		var position_value: Variant = entry.get("position", [0.0, 0.0, 0.0])
		var values: Array = position_value
		text += "%s\t%s\t%.3f\t%.3f\t%.3f\n" % [
			String(entry.get("id", "")), String(entry.get("tag", "other")),
			float(values[0]), float(values[1]), float(values[2]),
		]
	return parse_text(text).get("candidates", [] as Array[Dictionary])
