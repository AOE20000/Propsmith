extends MapSource
class_name PlateauMapSource
## The built-in map: a PLATEAU (Japan MLIT 3D city model) district, loaded from
## CityGML through the community `godot-plateau` GDExtension.
##
## Two hard rules from the project's conventions shape this file:
##   1. The SDK is an *optional* extension. It is never written into
##      `project.godot`; availability is probed through `ClassDB` and a missing
##      SDK degrades into an actionable error, not a crash. (With the default map
##      being a PLATEAU city the game cannot start without it, but the failure
##      still names what to install instead of printing an unknown identifier.)
##   2. The map data itself (hundreds of MB per city) never enters the repository.
##      It is downloaded with `tools/plateau/scan_cities.py` into `data/`, which
##      is gitignored; a missing dataset is again an actionable error.
##
## Coordinate handling: PLATEAU is EPSG:6697, and the data files are cut per
## standard grid square. `PLATEAUGeoReference` with zone 9 (JGD2011 plane
## rectangular coordinate system, Tokyo) plus one shared `reference_point`
## projects every file into the same local metre frame with the reference at the
## origin — that shared frame is what makes multiple files line up.
##
## The ground: CityGML building meshes have no floor you can stand on, so the
## source stamps a flat ground plane at y = 0 and shifts the loaded city so its
## lowest point sits on that plane. A terrain-following ground (PLATEAUTerrain /
## HeightMapAligner) is the next milestone, not this one.
##
## Collision: `PLATEAUImporter.generate_collision` builds the physics meshes,
## and every collision body is stamped with `SurfaceQuery.GROUND_MASK` so the
## surface query sees exactly the map and nothing that walks.

const DEFAULT_CITY: String = "shibuya"
## JGD2011 plane rectangular coordinate system zone 9 covers Tokyo (and Shibuya).
const ZONE_ID: int = 9
## Half-extent of the flat ground plane, in metres. The plane must cover not
## just the loaded blocks but wherever they sit *in the dataset frame* — a
## subset of Shibuya can sit ~2 km from the ward centre — plus margin.
const GROUND_HALF_EXTENT: float = 6000.0
const GROUND_THICKNESS: float = 2.0

## Spawn search: rings outward from the origin, accepting the first outdoor
## spot — `height_at` near the ground plane and nearly flat. Rooftops are also
## flat, but their sampled height is far above 0, which is what excludes them.
const SPAWN_MAX_RADIUS: float = 160.0
const SPAWN_RING_STEP: float = 8.0
const SPAWN_RING_SAMPLES: int = 12
const SPAWN_MAX_SLOPE_DEGREES: float = 12.0
const SPAWN_GROUND_TOLERANCE: float = 1.5
## How far from a candidate the "is there a building here at all" probes run.
const NEARBY_BUILDING_RADIUS: float = 16.0
## Hard clearance: a candidate with a building face within this distance would
## put the player against a wall with the third-person camera inside geometry,
## which the first "fully surrounded" pick demonstrated from inside a building.
const SPAWN_CLEARANCE_RADIUS: float = 5.0

var city: String = ""
## Facts filled in during `build`, reported by `describe()`.
var buildings_loaded: int = 0
var files_loaded: int = 0
var collision_bodies: int = 0
var load_duration_ms: int = 0
## The offset applied to the city container by `_settle_city_transform`, reported
## so the boot log shows how far the data was from the world origin.
var city_offset: Vector3 = Vector3.ZERO
## `MobilityReadiness.assess` result for this city's place table, plus how many
## agents actually spawned. Empty report = no place table was found.
var mobility_report: Dictionary = {}
var mobility_agents: int = 0
## Which `DemoLook` preset this city was lit with, reported by `describe()`.
var _look_preset: StringName = &"city"

## Crowd size for the first walking-city milestone. Fixed rather than scaled:
## the point is to prove the pipeline (table → readiness → routes → bodies that
## slide along building walls), and a fixed number keeps the boot cost predictable.
const MOBILITY_AGENT_COUNT: int = 40
## Tags the builtin patterns actually ask for; absent ones get named as
## "will be substituted" in the readiness line instead of failing silently.
const MOBILITY_REQUIRED_TAGS: Array[StringName] = [&"home", &"work", &"food"]

var _spawn_position: Vector3 = Vector3.ZERO
var _reference_point: Vector3 = Vector3.ZERO
## Mean of per-building AABB centres, in world space — where the buildings
## actually cluster. The AABB midpoint of the whole district can sit in a park,
## a rail cutting or a river, which is exactly where the first spawn search
## dropped the player: skyline in the distance, nothing around.
var _density_centre: Vector3 = Vector3.ZERO


func build(world_root: Node3D, seed_value: int) -> bool:
	city = _env_or("DSH_MAP_CITY", DEFAULT_CITY)
	var max_files: int = int(_env_or("DSH_MAP_FILES", "1"))
	var lod: int = int(_env_or("DSH_MAP_LOD", "1"))

	Events.world_generation_started.emit(seed_value)
	var progress := func(step: String, ratio: float) -> void:
		Events.world_generation_progress.emit(step, ratio)

	progress.call("探测 PLATEAU SDK", 0.02)
	if not sdk_available():
		push_error("PLATEAU SDK 未安装：缺少 addons/plateau（shiena/godot-plateau GDExtension）。复制该目录后重启 Godot。")
		return false

	progress.call("定位地图数据", 0.08)
	var gml_files: PackedStringArray = _find_gml_files(city, "bldg")
	if gml_files.is_empty():
		push_error("未找到 PLATEAU 地图数据（城市 %s）。运行 tools/plateau/scan_cities.py --areas 渋谷区 --max-mb 800 --keep --work-dir data/plateau-scan 下载，然后将其解压目录放入 data/plateau/%s；或用 DSH_MAP_DATA 指向数据根目录。" % [city, city])
		return false
	if max_files > 0 and gml_files.size() > max_files:
		gml_files = gml_files.slice(0, max_files)

	progress.call("加载街区建筑", 0.15)
	var started_at: int = Time.get_ticks_msec()
	var city_container := Node3D.new()
	city_container.name = "City"
	world_root.add_child(city_container)

	# One shared geographic reference, built from the *first* file before any
	# scene exists: every later file is projected against the same anchor, which
	# is what lines the grid squares up. Building it lazily inside the loop would
	# silently re-anchor per file and stack the whole city on one point.
	var geo: Variant = null
	var options: Variant = null
	for index: int in gml_files.size():
		var gml_path: String = gml_files[index]
		if geo == null:
			var probe_model: Variant = _load_model(gml_path)
			if probe_model == null:
				push_error("PLATEAU 文件加载失败：%s" % gml_path)
				return false
			geo = _make_geo_reference(probe_model)
			options = _make_extract_options(lod)
		if not _import_gml(gml_path, city_container, geo, options):
			# A grid square can legitimately hold no buildings (parks, water), so
			# one bad file is a warning, not a failed boot. A map that ends up
			# with nothing loaded is still fatal, checked below.
			push_warning("PLATEAU 文件跳过（加载失败或无建筑网格）：%s" % gml_path)
			continue
		progress.call("加载街区建筑 %d/%d" % [index + 1, gml_files.size()], 0.15 + 0.55 * float(index + 1) / float(gml_files.size()))
	load_duration_ms = Time.get_ticks_msec() - started_at
	if files_loaded == 0:
		push_error("PLATEAU 数据加载后没有任何建筑网格：%s（检查 DSH_MAP_LOD 与数据完整性）" % city)
		return false

	progress.call("生成碰撞与地表", 0.75)
	_stamp_ground_physics(city_container)
	_build_ground_plane(world_root)
	_settle_city_transform(city_container)
	# Geometry is in the physics space now, so queries may answer. Marking here
	# (not in the boot sequence) is what lets this same build() find its own
	# spawn point below.
	(Services.get_as(&"surface_query", &"SurfaceQuery") as SurfaceQuery).mark_ready()

	progress.call("构建天空与光照", 0.88)
	_build_environment(world_root)

	progress.call("通知 Mod 介入地图", 0.94)
	ModHost.notify_world_generate(world_root)

	progress.call("通知 Mod 补充内容", 0.98)
	ModHost.notify_world_populate(world_root)

	progress.call("生成人流", 0.99)
	_build_mobility(world_root, city_container, seed_value)
	# The mobility step may re-anchor the city to the place table's whole-dataset
	# offset — which moves every building by kilometres. The spawn search and the
	# density anchor therefore run AFTER that, or the player spawns on the old
	# empty coordinate with the skyline gone.
	_spawn_position = _find_spawn_position()
	spawn_anchor = _density_centre

	progress.call("完成", 1.0)
	return true


func find_spawn_position() -> Vector3:
	return _spawn_position


func map_id() -> String:
	# The dataset fingerprint (all bldg file names, hashed) — deliberately NOT
	# the loaded-file count: a place table can cover the whole ward while a
	# session loads one square, and that is the same map. A re-downloaded
	# dataset changes the names, which is what this must react to.
	return "plateau:%s:%d:%s" % [city, _active_lod(), _dataset_fingerprint()]


func describe() -> Dictionary:
	return {
		"city": city,
		"files_loaded": files_loaded,
		"buildings": buildings_loaded,
		"load_ms": load_duration_ms,
		"collision_bodies": collision_bodies,
		"reference": _reference_point,
		"offset": city_offset,
		"mobility": MobilityReadiness.describe(mobility_report) if not mobility_report.is_empty() else "无地点表（运行 tools/city_export_activity 导出）",
		"agents": mobility_agents,
		"look": "%s / %s" % [_look_preset, DemoLook.label(_look_preset)],
		# Asked for and actually built are reported separately: if the figure asset
		# is missing, `dressing` says "0 人" while `crowd` still says "vrm", and the
		# disagreement is the diagnostic.
		"crowd": "%d 人 · 外观 %s" % [mobility_agents, NpcFigure.default_appearance()],
		"dressing": NpcFigure.cost_report(),
	}


## The walking city: load the exported place table, ask `MobilityReadiness` whether
## tag-driven mobility can run on it, and if so resolve a seeded day for each
## agent. The path finder is the straight line between places for now — bodies
## slide along building walls via `move_and_slide`, which keeps people out of
## geometry without a navigation bake; the route's injection point is where a
## road-network finder plugs in later.
func _build_mobility(world_root: Node3D, city_container: Node3D, seed_value: int) -> void:
	var table: Dictionary = _load_place_table()
	var candidates: Array[Dictionary] = table.get("candidates", [] as Array[Dictionary])
	if candidates.is_empty():
		return
	# The table was derived from a specific dataset (fingerprinted by file
	# names). If the running map no longer matches, positions would be subtly
	# wrong — people inside walls — so the table is refused rather than trusted.
	var exported_version: String = String(table.get("map_version", ""))
	if exported_version != map_id():
		push_warning("地点表版本不匹配（表：%s，当前：%s）——重新运行 tools/city_export_activity 导出" % [
			exported_version, map_id(),
		])
		return
	# The exported offset covers the WHOLE dataset; a session that loaded a
	# subset settled itself against only that subset's AABB, which sits
	# kilometres away. Adopting the table's offset (computed over everything)
	# puts the loaded blocks and the place table into the exact same frame —
	# people at building footprints, not inside walls. Queries go through the
	# physics bodies, which move with the container, so nothing else cares.
	var table_offset: Vector3 = table.get("offset", Vector3.ZERO)
	if table_offset != Vector3.ZERO:
		var previous: Vector3 = city_container.position
		city_container.position = table_offset
		city_offset = table_offset
		# The measured building cluster moves with the container; the anchor
		# used by the spawn search must follow or it points kilometres away.
		_density_centre += city_container.position - previous
	# The full ward is ~90k places — scoring all of them per step per agent is
	# millions of evaluations for no visible gain, since agents only ever walk
	# near where the session loaded. Keep places near the loaded blocks, then
	# cap each tag by stride sampling, which preserves spatial spread.
	candidates = _thin_candidates(candidates)
	if candidates.is_empty():
		return
	mobility_report = MobilityReadiness.assess(candidates, MOBILITY_REQUIRED_TAGS)
	if not bool(mobility_report["enabled"]):
		return

	var version: String = map_id()
	var cache := RouteCache.new()
	cache.set_map_version(version)

	var positions: Dictionary = {}
	for candidate: Dictionary in candidates:
		positions[String(candidate.get("id", ""))] = candidate.get("position", Vector3.ZERO)
	var finder := func(from_key: String, to_key: String) -> PackedVector3Array:
		var from_position: Variant = positions.get(from_key)
		var to_position: Variant = positions.get(to_key)
		if from_position == null or to_position == null:
			return PackedVector3Array()
		return PackedVector3Array([Vector3(from_position), Vector3(to_position)])

	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%s|mobility|%d" % [version, seed_value])
	var patterns: Array[ActivityPattern] = ActivityPattern.all_builtin()

	var container := Node3D.new()
	container.name = "Pedestrians"
	world_root.add_child(container)

	# Bind once: menu-spawned citizens join the same day-planned crowd.
	var spawner: PropSpawner = Services.get_as(&"prop_spawner", &"PropSpawner") as PropSpawner
	if spawner != null:
		spawner.bind_mobility(candidates, cache, version, finder, patterns)

	var spawned: int = 0
	var attempts: int = 0
	while spawned < MOBILITY_AGENT_COUNT and attempts < MOBILITY_AGENT_COUNT * 3:
		attempts += 1
		var home: Dictionary = candidates[rng.randi() % candidates.size()]
		if StringName(home.get("tag", ActivityTag.OTHER)) == ActivityTag.OTHER:
			continue  # A home nobody annotated is not a home; pick another.
		var origin: Vector3 = home.get("position", Vector3.ZERO) + Vector3(
			rng.randf_range(-1.5, 1.5), 0.4, rng.randf_range(-1.5, 1.5)
		)
		var agent: PedestrianAgent = spawner.spawn_citizen(origin, seed_value + spawned)
		if agent == null or not agent.has_day():
			if agent != null:
				agent.queue_free()
			continue
		if container != agent.get_parent():
			agent.get_parent().remove_child(agent)
			container.add_child(agent)
		spawned += 1
	mobility_agents = spawned


## The place table sits beside the dataset it was derived from; the same
## DSH_MAP_DATA / DSH_MAP_CITY environment knobs apply.
func _load_place_table() -> Dictionary:
	var data_root: String = _env_or("DSH_MAP_DATA", "res://data/plateau")
	return PlaceTable.load_for(city, data_root)


## The SDK is still treated as an optional extension everywhere else in the
## project, so this probe — not a compile-time class reference — is the gate.
## Class names live here and nowhere else, which keeps the "never type a
## GDExtension class" rule auditable.
func sdk_available() -> bool:
	return (
		ClassDB.class_exists(&"PLATEAUCityModel")
		and ClassDB.class_exists(&"PLATEAUImporter")
		and ClassDB.class_exists(&"PLATEAUMeshExtractOptions")
		and ClassDB.class_exists(&"PLATEAUGeoReference")
	)


## Load one CityGML file: parse, extract meshes, and import the scene under
## `city_container`. Returns false when the file carries no usable mesh — a
## caller decides whether that is fatal. GDExtension classes are held as
## `Variant` throughout and probed via `ClassDB` at the gate: a missing SDK must
## be a diagnosable runtime failure, never a compile-time dependency.
func _import_gml(gml_path: String, city_container: Node3D, geo: Variant, options: Variant) -> bool:
	var model: Variant = _load_model(gml_path)
	if model == null:
		return false

	var meshes: Array = model.extract_meshes(options)
	var flat: Array = []
	_flatten_meshes(meshes, flat)
	buildings_loaded += flat.size()
	if flat.is_empty():
		return false

	var importer: Variant = ClassDB.instantiate(&"PLATEAUImporter")
	importer.generate_collision = true
	var scene_root: Node = importer.import_to_scene(flat, city, geo, options, gml_path)
	if scene_root == null:
		return false
	city_container.add_child(scene_root)
	files_loaded += 1
	return true


func _load_model(gml_path: String) -> Variant:
	var model: Variant = ClassDB.instantiate(&"PLATEAUCityModel")
	# The constant is read from ClassDB rather than written as a literal — the SDK
	# owns its enum values, and "quiet in a boot log" is its documented meaning.
	var error_level: int = ClassDB.class_get_integer_constant(&"PLATEAUCityModel", "LOG_LEVEL_ERROR")
	model.log_level = error_level
	if not model.load(gml_path):
		return null
	return model


func _make_geo_reference(model: Variant) -> Variant:
	var geo: Variant = ClassDB.instantiate(&"PLATEAUGeoReference")
	geo.zone_id = ZONE_ID
	# `get_center_point` returns geographic degrees + elevation; it is the SDK's
	# own projection anchor. (The SDK's `get_latitude()` *getter* is untrustworthy
	# per M0 — this is the envelope-derived centre, which measured correct.)
	_reference_point = model.get_center_point(ZONE_ID)
	geo.reference_point = _reference_point
	return geo


func _make_extract_options(lod: int) -> Variant:
	var options: Variant = ClassDB.instantiate(&"PLATEAUMeshExtractOptions")
	options.coordinate_zone_id = ZONE_ID
	options.min_lod = lod
	options.max_lod = lod
	options.mesh_granularity = 1  # one mesh per building — per-building queries later
	options.export_appearance = lod >= 2  # LOD1 is the untextured block model
	return options


## `extract_meshes` returns a hierarchy (root -> LOD -> per-building entries); the
## leaves carry the mesh, the gml id and the attributes. Mirrors the SDK sample's
## `flatten_mesh_data`. Held as `Variant` on purpose — see `_import_gml`.
func _flatten_meshes(entries: Array, out: Array) -> void:
	for entry: Variant in entries:
		if entry.get_mesh() != null:
			out.append(entry)
		_flatten_meshes(entry.get_children(), out)


## Every collision body under the city gets the map's physics bit, and the ones
## the importer did not build (SDK behaviour varies by version) get a trimesh
## fallback. Bodies are also grouped so `SurfaceQuery.surface_kind` can tell a
## rooftop from the street without depending on SDK node names.
func _stamp_ground_physics(city_container: Node3D) -> void:
	var stack: Array[Node] = [city_container]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child: Node in node.get_children():
			stack.append(child)
		if node is CollisionObject3D:
			var body: CollisionObject3D = node
			body.collision_layer = 1 | SurfaceQuery.GROUND_MASK
			body.collision_mask = 0
			body.add_to_group(&"map_buildings")
			collision_bodies += 1
		elif node is MeshInstance3D and node.get_child_count() == 0:
			# A mesh with no collision sibling: build one ourselves.
			var mesh_instance: MeshInstance3D = node
			if mesh_instance.mesh != null:
				var before: int = mesh_instance.get_child_count()
				mesh_instance.create_trimesh_collision()
				if mesh_instance.get_child_count() > before:
					var generated: Node = mesh_instance.get_child(mesh_instance.get_child_count() - 1)
					if generated is CollisionObject3D:
						var body: CollisionObject3D = generated
						body.collision_layer = 1 | SurfaceQuery.GROUND_MASK
						body.collision_mask = 0
						body.add_to_group(&"map_buildings")
						collision_bodies += 1


## A flat stand-in ground at y = 0. Not vanity: without it the first milestone has
## no floor between buildings, and every spawn/parking query lands in the void.
func _build_ground_plane(world_root: Node3D) -> void:
	var ground := StaticBody3D.new()
	ground.name = "CityGround"
	ground.collision_layer = 1 | SurfaceQuery.GROUND_MASK
	ground.collision_mask = 0
	var shape := CollisionShape3D.new()
	shape.name = "GroundShape"
	var box := BoxShape3D.new()
	box.size = Vector3(GROUND_HALF_EXTENT * 2.0, GROUND_THICKNESS, GROUND_HALF_EXTENT * 2.0)
	shape.shape = box
	ground.position = Vector3(0.0, -GROUND_THICKNESS * 0.5, 0.0)
	ground.add_child(shape)
	world_root.add_child(ground)


## The importer leaves vertices in JGD2011 zone-9 *absolute* metre coordinates —
## measured: Shibuya lands ~11 km west and ~40 km south of the zone origin, and
## `geo.reference_point` does **not** translate the imported scene (the M0 probe
## only checked `transform.origin`, which is small, and mistook that for local
## coordinates). So the plan's §5.3 rule — city centre at the world origin — is
## implemented here, by hand: one container offset centres the loaded district
## horizontally and drops its lowest point onto the y = 0 ground plane.
## Single-precision float drift starts mattering tens of kilometres out, which
## makes this the first defence, not a nicety.
func _settle_city_transform(city_container: Node3D) -> void:
	var minimum := Vector3.INF
	var maximum := -Vector3.INF
	var centre_sum := Vector3.ZERO
	var centre_count: int = 0
	var stack: Array[Node] = [city_container]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child: Node in node.get_children():
			stack.append(child)
		if node is MeshInstance3D:
			var mesh_instance: MeshInstance3D = node
			if mesh_instance.mesh != null and mesh_instance.mesh.get_surface_count() > 0:
				var aabb: AABB = mesh_instance.global_transform * mesh_instance.mesh.get_aabb()
				minimum = minimum.min(aabb.position)
				maximum = maximum.max(aabb.position + aabb.size)
				centre_sum += aabb.get_center()
				centre_count += 1
	if not is_finite(minimum.x):
		return
	var centre := (minimum + maximum) * 0.5
	city_container.position = Vector3(-centre.x, -minimum.y, -centre.z)
	city_offset = Vector3(-centre.x, -minimum.y, -centre.z)
	# Building centres measured *before* the container moved; shifting them once
	# here is cheaper than walking the tree again. This is the spawn anchor.
	if centre_count > 0:
		_density_centre = centre_sum / float(centre_count) + city_container.position


## Sky, sun and post-processing, from the demo's shared baseline with the city's
## own preset: the island's environment stage went with the island, and the city
## was left on a hand-rolled sky that predated the baseline. Asking `DemoLook`
## for `city` keeps the cool, grey temperature the district already had while
## picking up the shared exposure curve, bloom and ambient occlusion — the same
## values that will be tuned for the demo, so the two maps stay one game.
##
## Screen-space reflections stay off in this preset: the district is far too much
## geometry to spend a per-pixel ray march on.
func _build_environment(world_root: Node3D) -> void:
	_look_preset = &"city"
	DemoLook.apply(world_root, _look_preset)


## Rings outward from the building cluster, first outdoor flat spot wins —
## with one extra requirement the first version lacked: the spot must have
## buildings *nearby*, because the district's geometric midpoint can be a park,
## a river or a rail yard, and "flat ground at the origin" once meant spawning
## on empty tarmac with the skyline a street district away.
##
## Rooftops are also flat, but their sampled height is far above 0, which is
## what excludes them.
func _find_spawn_position() -> Vector3:
	var query: SurfaceQuery = Services.get_as(&"surface_query", &"SurfaceQuery") as SurfaceQuery
	if query == null or not query.is_ready():
		return Vector3(0.0, 2.0, 0.0)

	var anchor: Vector3 = _density_centre
	var best_position := Vector3.ZERO
	var best_score: float = -1.0
	var radius: float = SPAWN_RING_STEP
	# Citizens spawn clustered on building footprints near the anchor; a player
	# dropped into that crowd gets shoved by forty bodies. The clear-shape check
	# keeps the spawn point free of *anything* dynamic, not just buildings.
	var space := _physics_space()
	var clear_shape := SphereShape3D.new()
	clear_shape.radius = SPAWN_CLEARANCE_RADIUS
	while radius <= SPAWN_MAX_RADIUS:
		for step: int in SPAWN_RING_SAMPLES:
			var angle: float = TAU * float(step) / float(SPAWN_RING_SAMPLES)
			var x: float = anchor.x + cos(angle) * radius
			var z: float = anchor.z + sin(angle) * radius
			var height: float = query.height_at(x, z)
			if absf(height) > SPAWN_GROUND_TOLERANCE:
				continue
			if query.slope_degrees_at(x, z) > SPAWN_MAX_SLOPE_DEGREES:
				continue
			if not _is_clear_of_buildings(query, x, z):
				continue
			if space != null:
				var overlap := PhysicsShapeQueryParameters3D.new()
				overlap.shape = clear_shape
				overlap.transform = Transform3D(Basis(), Vector3(x, height, z))
				overlap.collision_mask = 1
				if not space.intersect_shape(overlap, 1).is_empty():
					continue
			var score: float = _nearby_building_fraction(query, x, z)
			if score > best_score:
				best_score = score
				best_position = Vector3(x, height + 1.0, z)
			if score >= 0.99:
				# Fully surrounded is as good as this probe gets; take it and
				# don't walk the remaining rings.
				radius = SPAWN_MAX_RADIUS + 1.0
				break
		radius += SPAWN_RING_STEP
	if best_score >= 0.0:
		return best_position
	# No legal outdoor spot near the cluster: spawn on top of whatever is at the
	# anchor and let physics settle it, rather than failing the boot.
	return Vector3(anchor.x, query.height_at(anchor.x, anchor.z) + 2.0, anchor.z)


## Fraction of probe rays around (x, z) that hit a building footprint — the
## measure of "this is a street between buildings" the spawn search scores by.
func _nearby_building_fraction(query: SurfaceQuery, x: float, z: float) -> float:
	var hits: int = 0
	var total: int = 0
	for step: int in SPAWN_RING_SAMPLES:
		var angle: float = TAU * float(step) / float(SPAWN_RING_SAMPLES)
		var kind: StringName = query.surface_kind(
			x + cos(angle) * NEARBY_BUILDING_RADIUS, z + sin(angle) * NEARBY_BUILDING_RADIUS
		)
		total += 1
		if kind == &"building":
			hits += 1
	return float(hits) / float(maxi(total, 1))


## The clearance half of the spawn test: nothing architectural within arm's
## reach of the candidate, so the player stands in the open and the third-person
## camera starts outside geometry. Four probes, not eight — corners are close
## enough to the axes at this radius.
func _is_clear_of_buildings(query: SurfaceQuery, x: float, z: float) -> bool:
	for angle_step: int in 4:
		var angle: float = TAU * float(angle_step) / 4.0
		if query.surface_kind(x + cos(angle) * SPAWN_CLEARANCE_RADIUS, z + sin(angle) * SPAWN_CLEARANCE_RADIUS) == &"building":
			return false
	return true


## The physics space for the spawn-time overlap probe.
func _physics_space() -> PhysicsDirectSpaceState3D:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	return tree.root.world_3d.direct_space_state


## Places near the loaded blocks (within ACTIVE_RADIUS of the origin — the
## reference point sits mid-dataset), then at most MAX_PER_TAG per activity tag
## by stride, which keeps their spatial spread instead of clustering.
const ACTIVE_RADIUS: float = 800.0
const MAX_PER_TAG: int = 300

func _thin_candidates(candidates: Array[Dictionary]) -> Array[Dictionary]:
	var nearby: Array[Dictionary] = []
	for candidate: Dictionary in candidates:
		if (candidate.get("position", Vector3.ZERO) as Vector3).length() <= ACTIVE_RADIUS:
			nearby.append(candidate)
	var by_tag: Dictionary = {}
	for candidate: Dictionary in nearby:
		var tag: StringName = StringName(candidate.get("tag", ActivityTag.OTHER))
		if not by_tag.has(tag):
			by_tag[tag] = []
		(by_tag[tag] as Array).append(candidate)
	var thinned: Array[Dictionary] = []
	for tag: Variant in by_tag:
		var bucket: Array = by_tag[tag]
		var stride: int = maxi(1, int(ceil(float(bucket.size()) / float(MAX_PER_TAG))))
		for index: int in bucket.size():
			if index % stride == 0:
				thinned.append(bucket[index])
	return thinned


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


func _active_lod() -> int:
	return int(_env_or("DSH_MAP_LOD", "1"))


## The fingerprint over the **full** dataset, independent of how many files the
## session chose to load.
func _dataset_fingerprint() -> String:
	return PlateauReader.dataset_fingerprint(_find_gml_files(city, "bldg"))


func _env_or(key: String, fallback: String) -> String:
	var value: String = OS.get_environment(key)
	return value if not value.is_empty() else fallback
