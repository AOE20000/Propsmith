extends RefCounted
class_name PlateauReader
## The one place that talks to the godot-plateau SDK's extraction path: load a
## CityGML file, pull out per-building mesh data, read its attributes, and measure
## where the buildings are.
##
## Two consumers share it — `PlateauMapSource` (builds the playable city) and the
## activity export probe (`tools/city_export_activity.gd`, builds the place table).
## Sharing is not tidiness, it is correctness: the place table's positions and the
## city's meshes must agree on the *same* world offset, or the people walk into
## walls. Everything here holds the SDK classes as `Variant` and probes via
## `ClassDB` — never as types (the optional-extension rule).

const USAGE_KEY: String = "bldg:usage"


func _init() -> void:
	push_error("PlateauReader is static-only; do not instantiate it")


## Load one CityGML file and extract one mesh entry per building.
## Returns an empty array on failure (the caller decides whether that is fatal).
static func extract_buildings(gml_path: String, lod: int) -> Array:
	if not ClassDB.class_exists(&"PLATEAUCityModel"):
		push_error("PLATEAU SDK 未安装：缺少 addons/plateau（godot-plateau GDExtension）。")
		return []
	var model: Variant = ClassDB.instantiate(&"PLATEAUCityModel")
	# The constant comes from ClassDB, not a literal: the SDK owns its enum values.
	model.log_level = ClassDB.class_get_integer_constant(&"PLATEAUCityModel", "LOG_LEVEL_ERROR")
	print("[plateau] load %s ..." % gml_path.get_file())
	var load_started: int = Time.get_ticks_msec()
	if not model.load(gml_path):
		push_warning("PlateauReader: 无法加载 %s" % gml_path)
		return []
	print("[plateau]   loaded in %d ms" % (Time.get_ticks_msec() - load_started))
	var extract_started: int = Time.get_ticks_msec()
	var options: Variant = ClassDB.instantiate(&"PLATEAUMeshExtractOptions")
	options.coordinate_zone_id = PlateauMapSource.ZONE_ID
	options.min_lod = lod
	options.max_lod = lod
	options.mesh_granularity = 1  # one mesh per building
	options.export_appearance = lod >= 2
	var flat: Array = []
	_flatten(model.extract_meshes(options), flat)
	print("[plateau]   %d buildings in %d ms" % [flat.size(), Time.get_ticks_msec() - extract_started])
	return flat


## `extract_meshes` returns a hierarchy (root -> LOD -> per-building entries); the
## leaves carry mesh, gml id and attributes. Mirrors the SDK sample's flatten.
static func _flatten(entries: Array, out: Array) -> void:
	for entry: Variant in entries:
		if entry.get_mesh() != null:
			out.append(entry)
		_flatten(entry.get_children(), out)


## The building's centre in JGD2011 zone-9 absolute metres (measured fact: the
## vertices carry absolute coordinates — Shibuya sits ~11 km west / ~40 km south
## of the zone origin; `geo.reference_point` does not translate them).
static func zone_centre(data: Variant) -> Vector3:
	var mesh: Variant = data.get_mesh()
	if mesh == null or mesh.get_surface_count() == 0:
		return Vector3.ZERO
	var aabb: AABB = data.get_transform() * mesh.get_aabb()
	return aabb.get_center()


## The combined AABB of every entry, in the same zone-absolute frame.
## Returns the invalid `AABB()` (position == size == ZERO with a negated end)
## check via `has_volume()` on the caller side.
static func combined_aabb(entries: Array) -> AABB:
	var combined := AABB()
	var first: bool = true
	for data: Variant in entries:
		var mesh: Variant = data.get_mesh()
		if mesh == null or mesh.get_surface_count() == 0:
			continue
		var aabb: AABB = data.get_transform() * mesh.get_aabb()
		if first:
			combined = aabb
			first = false
		else:
			combined = combined.merge(aabb)
	return combined


## The building's `bldg:usage` value, with the two measured data traps applied:
## attribute keys are **lowercase** (the SDK docs' camelCase silently returns
## null — so the lookup is case-insensitive over the real keys), and unknown
## sentinels / missing values come back as an empty string for the caller to
## treat as "unannotated".
static func usage_of(data: Variant) -> String:
	var attributes: Dictionary = data.get_attributes()
	for key: Variant in attributes:
		if String(key).to_lower() == USAGE_KEY:
			var value: Variant = attributes[key]
			if value == null:
				return ""
			var text: String = str(value).strip_edges()
			# `9999` is the dataset's "unknown" sentinel in several numeric
			# fields; a usage code of 461 ("不明") already normalises to `other`
			# downstream, but the sentinel must never read as a real code.
			if text == "9999" or text == "0001":
				return ""
			return text
	return ""


## The gml id, for stable place identity across exports.
static func gml_id_of(data: Variant) -> String:
	var id: Variant = data.get_gml_id()
	return String(id) if id != null else ""
