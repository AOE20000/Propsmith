extends Node
## Offline exporter: walk every building in the configured city, read its
## `bldg:usage`, and write the annotated place table the mobility layer routes
## between. Run headless once after downloading a dataset:
##
##   godot --headless --path . res://tools/city_export_activity.tscn --quit-after 6000
##
## Output: `data/plateau/<city>/activity.json` (gitignored, like the dataset
## itself — CI uses the synthetic fixture in the tests instead). The position
## formula and the map_version string must agree with `PlateauMapSource` — that
## agreement is what keeps agents out of walls, so both sides go through
## `PlateauReader` and the same constants rather than duplicating arithmetic.

const OUTPUT_SUFFIX: String = "activity.json"


func _ready() -> void:
	var city: String = _env_or("DSH_MAP_CITY", PlateauMapSource.DEFAULT_CITY)
	var lod: int = int(_env_or("DSH_MAP_LOD", "1"))
	var max_files: int = int(_env_or("DSH_MAP_FILES", "0"))  # 0 = every file

	var gml_files: PackedStringArray = _find_gml_files(city, "bldg")
	if gml_files.is_empty():
		printerr("[export] 未找到数据：city=%s（先运行 tools/plateau/scan_cities.py 下载）" % city)
		get_tree().quit(1)
		return
	if max_files > 0 and gml_files.size() > max_files:
		gml_files = gml_files.slice(0, max_files)

	var started_at: int = Time.get_ticks_msec()
	var entries: Array = []
	for index: int in gml_files.size():
		var batch: Array = PlateauReader.extract_buildings(gml_files[index], lod)
		print("[export] %d/%d %s: %d buildings" % [index + 1, gml_files.size(), gml_files[index].get_file(), batch.size()])
		entries.append_array(batch)
	print("[export] total buildings=%d in %d ms" % [entries.size(), Time.get_ticks_msec() - started_at])
	if entries.is_empty():
		printerr("[export] no buildings extracted")
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

	var map_version: String = "plateau:%s:%d:%d" % [city, lod, gml_files.size()]
	var payload := {
		"city": city,
		"lod": lod,
		"map_version": map_version,
		"offset": [offset.x, offset.y, offset.z],
		"buildings": places.size(),
		"tagged": tagged,
		"places": places,
	}

	var output_path: String = ProjectSettings.globalize_path(
		"res://data/plateau".path_join(city).path_join(OUTPUT_SUFFIX)
	)
	DirAccess.make_dir_recursive_absolute(output_path.get_base_dir())
	var file: FileAccess = FileAccess.open(output_path, FileAccess.WRITE)
	if file == null:
		printerr("[export] cannot write %s" % output_path)
		get_tree().quit(1)
		return
	file.store_string(JSON.stringify(payload))
	file.close()

	print("[export] %s" % map_version)
	print("[export] offset=(%.1f, %.1f, %.1f) tagged=%d/%d" % [
		offset.x, offset.y, offset.z, tagged, places.size(),
	])
	print("[export] wrote %s" % output_path)
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
