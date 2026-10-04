extends Node
## Offline exporter: walk every building in the configured city, read its
## `bldg:usage`, and write the annotated place table the mobility layer routes
## between. Run headless once after downloading a dataset:
##
##   godot --headless --path . res://tools/city_export_activity.tscn --quit-after 200000
##
## Output: `data/plateau/<city>/activity.json` (gitignored, like the dataset
## itself — CI uses the synthetic fixture in the tests instead). The position
## formula and the map_version string must agree with `PlateauMapSource` — that
## agreement is what keeps agents out of walls, so both sides go through
## `PlateauReader` and the same constants rather than duplicating arithmetic.
##
## Progress goes to a **flush-per-line journal file** (`data/plateau-scan/
## export_progress.log`), because stdout/stderr are buffered under Windows
## pipes and vanish entirely if the process dies mid-run — which is exactly how
## a crash inside one dataset file used to look like "no output at all".

const OUTPUT_SUFFIX: String = "activity.tsv"

var _journal: FileAccess = null


func _log_line(text: String) -> void:
	printerr(text)
	if _journal != null:
		_journal.store_line(text)
		_journal.flush()


func _ready() -> void:
	printerr("[export] alive")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://data/plateau-scan"))
	_journal = FileAccess.open(
		ProjectSettings.globalize_path("res://data/plateau-scan/export_progress.log"), FileAccess.WRITE
	)
	var city: String = _env_or("DSH_MAP_CITY", PlateauMapSource.DEFAULT_CITY)
	var lod: int = int(_env_or("DSH_MAP_LOD", "1"))
	var max_files: int = int(_env_or("DSH_MAP_FILES", "0"))  # 0 = every file

	var gml_files: PackedStringArray = _find_gml_files(city, "bldg")
	_log_line("[export] city=%s lod=%d files=%d" % [city, lod, gml_files.size()])
	if gml_files.is_empty():
		_log_line("[export] 未找到数据（先运行 tools/plateau/scan_cities.py 下载）")
		get_tree().quit(1)
		return
	if max_files > 0 and gml_files.size() > max_files:
		gml_files = gml_files.slice(0, max_files)

	var started_at: int = Time.get_ticks_msec()
	var entries: Array = []
	for index: int in gml_files.size():
		var gml_path: String = gml_files[index]
		_log_line("[export] BEGIN %d/%d %s" % [index + 1, gml_files.size(), gml_path.get_file()])
		var batch: Array = PlateauReader.extract_buildings(gml_path, lod)
		_log_line("[export] DONE  %d/%d %s: %d buildings" % [index + 1, gml_files.size(), gml_path.get_file(), batch.size()])
		entries.append_array(batch)
	_log_line("[export] total buildings=%d in %d ms" % [entries.size(), Time.get_ticks_msec() - started_at])
	if entries.is_empty():
		_log_line("[export] no buildings extracted")
		get_tree().quit(1)
		return

	# The same settle arithmetic as PlateauMapSource._settle_city_transform: the
	# city's combined AABB centres horizontally and its lowest point drops to y=0.
	var combined: AABB = PlateauReader.combined_aabb(entries)
	var offset := Vector3(-combined.get_center().x, -combined.position.y, -combined.get_center().z)

	var places: Array = []
	var tagged: int = 0
	for data: Variant in entries:
		var usage: String = PlateauReader.usage_of(data)
		var tag: StringName = ActivityTag.normalize(usage)
		if tag != ActivityTag.OTHER:
			tagged += 1
		var mesh: Variant = data.get_mesh()
		if mesh == null or mesh.get_surface_count() == 0:
			continue
		var aabb: AABB = data.get_transform() * mesh.get_aabb()
		var centre: Vector3 = aabb.get_center() + offset
		# People stand at a building's foot, not inside its upper half: the
		# place is the footprint centre at ground level.
		var position := Vector3(centre.x, aabb.position.y + offset.y, centre.z)
		places.append({
			"id": PlateauReader.gml_id_of(data),
			"tag": String(tag),
			"position": [position.x, position.y, position.z],
		})

	var fingerprint: String = PlateauReader.dataset_fingerprint(gml_files)
	# The old identity format, kept in `map_version` so an older reader can still
	# refuse a table that does not belong to its data. The loader itself compares
	# `map_fingerprint`: the table's guarantee is "derived from that dataset", which
	# is about the data, not about who shipped it or what they called the version.
	var map_version: String = "plateau:%s:%d:%s" % [city, lod, fingerprint]
	# TSV, not JSON: Godot's JSON.parse_string crawls on a 10 MB document (the
	# full ward hung load for minutes), while a split-per-line parse is
	# milliseconds. Header lines carry the metadata the loader needs.
	var output_path: String = ProjectSettings.globalize_path(
		"res://data/plateau".path_join(city).path_join(OUTPUT_SUFFIX)
	)
	DirAccess.make_dir_recursive_absolute(output_path.get_base_dir())
	var file: FileAccess = FileAccess.open(output_path, FileAccess.WRITE)
	if file == null:
		_log_line("[export] cannot write %s" % output_path)
		get_tree().quit(1)
		return
	file.store_line("# plateau place table")
	file.store_line("# city=%s lod=%d map_version=%s map_fingerprint=%s" % [city, lod, map_version, fingerprint])
	file.store_line("# offset=%.3f %.3f %.3f" % [offset.x, offset.y, offset.z])
	file.store_line("# id\ttag\tx\ty\tz")
	for place: Dictionary in places:
		var position_values: Array = place.get("position", [0.0, 0.0, 0.0])
		file.store_line("%s\t%s\t%.3f\t%.3f\t%.3f" % [
			String(place.get("id", "")), String(place.get("tag", "other")),
			float(position_values[0]), float(position_values[1]), float(position_values[2]),
		])
	file.close()

	_log_line("[export] %s" % map_version)
	_log_line("[export] offset=(%.1f, %.1f, %.1f) tagged=%d/%d" % [
		offset.x, offset.y, offset.z, tagged, places.size(),
	])
	_log_line("[export] wrote %s" % output_path)
	get_tree().quit(0)


func _find_gml_files(city_name: String, kind: String) -> PackedStringArray:
	var data_root: String = _env_or("DSH_MAP_DATA", ProjectSettings.globalize_path("res://data/plateau"))
	var directory := DirAccess.open(data_root.path_join(city_name).path_join("udx").path_join(kind))
	var files: PackedStringArray = PackedStringArray()
	if directory == null:
		return files
	for file_name: String in directory.get_files():
		if file_name.ends_with(".gml"):
			files.append(data_root.path_join(city_name).path_join("udx").path_join(kind).path_join(file_name))
	files.sort()
	return files


func _env_or(key: String, fallback: String) -> String:
	var value: String = OS.get_environment(key)
	return value if not value.is_empty() else fallback
