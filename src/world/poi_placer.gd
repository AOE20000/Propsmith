extends RefCounted
class_name PoiPlacer
## Places the island's landmarks, plus any a mod registered.
##
## Spacing is enforced by rejection so landmarks never overlap, and positions are
## drawn from a seeded RNG, so the same seed always yields the same set of places
## to find. A landmark already discovered in a save is restored as discovered.

## One landmark definition. `style` selects procedural geometry for the built-in
## kinds; a mod instead supplies a `factory` callable returning a Node3D.
class PoiDefinition:
	var id: StringName
	var display_name: String
	var style: StringName = &"cairn"
	var discover_radius: float = 16.0
	var reward_item_id: StringName = &""
	var reward_amount: int = 0
	## Minimum distance to any already-placed landmark.
	var min_spacing: float = 120.0
	## Preferred ground: rejected above this slope.
	var max_slope_degrees: float = 22.0
	var factory: Callable = Callable()


var definitions: Array[PoiDefinition] = []


func _init() -> void:
	_add_builtin_definitions()


func _add_builtin_definitions() -> void:
	definitions.append(_make(&"watchtower_north", "北岭瞭望塔", &"watchtower", 16.0, &"", 0, 150.0, 24.0))
	definitions.append(_make(&"ruins_ring", "环石遗迹", &"ruins", 18.0, &"relic_shard", 1, 140.0, 18.0))
	definitions.append(_make(&"campsite_cove", "海湾营地", &"campsite", 14.0, &"supply_crate", 2, 130.0, 14.0))
	definitions.append(_make(&"crystal_grove", "晶簇林地", &"crystal", 16.0, &"crystal_dust", 3, 130.0, 20.0))
	definitions.append(_make(&"cairn_pass", "山口石堆", &"cairn", 12.0, &"", 0, 110.0, 30.0))


func _make(
	id: StringName, display_name: String, style: StringName, radius: float,
	reward_item: StringName, reward_amount: int, spacing: float, max_slope: float
) -> PoiDefinition:
	var definition := PoiDefinition.new()
	definition.id = id
	definition.display_name = display_name
	definition.style = style
	definition.discover_radius = radius
	definition.reward_item_id = reward_item
	definition.reward_amount = reward_amount
	definition.min_spacing = spacing
	definition.max_slope_degrees = max_slope
	return definition


## Place every landmark under `parent`. Returns the number placed.
func place(parent: Node3D, query: TerrainQuery, config: TerrainConfig) -> int:
	_append_mod_definitions()

	var container: Node3D = Node3D.new()
	container.name = "Landmarks"
	parent.add_child(container)

	var placed_positions: Array[Vector3] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = config.seed + 5150
	var placed: int = 0

	for definition: PoiDefinition in definitions:
		var position: Variant = _find_position(definition, query, config, rng, placed_positions)
		if position == null:
			push_warning("PoiPlacer: no suitable ground for landmark '%s'" % definition.id)
			continue
		var marker: PoiMarker = _instantiate_marker(definition, position)
		if marker == null:
			continue
		container.add_child(marker)
		placed_positions.append(position)
		placed += 1
	return placed


## Convert mod-registered POI factories into definitions. A factory may return a
## whole Node3D (full control) and may leave discovery to the core marker.
func _append_mod_definitions() -> void:
	var ordered: Array[Dictionary] = ModHost.content_ordered(&"poi")
	for entry: Dictionary in ordered:
		var factory: Callable = entry.get("factory", Callable())
		if not factory.is_valid():
			continue
		var definition := PoiDefinition.new()
		definition.id = StringName(String(entry.get("id", "mod_poi")))
		definition.display_name = String(entry.get("display_name", definition.id))
		definition.style = &"mod"
		definition.factory = factory
		definition.min_spacing = 90.0
		definitions.append(definition)


## Rejection sampling for a landmark site: on land, gentle enough, far enough from
## the landmarks already placed.
func _find_position(
	definition: PoiDefinition, query: TerrainQuery, config: TerrainConfig,
	rng: RandomNumberGenerator, taken: Array[Vector3]
) -> Variant:
	var attempt_limit: int = 320
	for attempt: int in attempt_limit:
		var radius: float = config.island_radius * sqrt(rng.randf()) * 0.92
		var angle: float = rng.randf() * TAU
		var x: float = cos(angle) * radius
		var z: float = sin(angle) * radius
		if not query.is_placeable(x, z, definition.max_slope_degrees):
			continue
		if query.height_at(x, z) < 2.0:
			continue
		var candidate := Vector3(x, query.height_at(x, z), z)
		var too_close: bool = false
		for existing: Vector3 in taken:
			if existing.distance_to(candidate) < definition.min_spacing:
				too_close = true
				break
		if too_close:
			continue
		return candidate
	return null


func _instantiate_marker(definition: PoiDefinition, position: Vector3) -> PoiMarker:
	var marker := PoiMarker.new()
	marker.configure(definition.id, definition.display_name, definition.discover_radius)
	marker.reward_item_id = definition.reward_item_id
	marker.reward_amount = definition.reward_amount
	marker.position = position

	var geometry: Node3D = null
	if definition.factory.is_valid():
		var produced: Variant = definition.factory.call()
		if produced is Node3D:
			geometry = produced
		else:
			push_warning("PoiPlacer: factory for '%s' did not return a Node3D" % definition.id)
	if geometry == null:
		geometry = PoiGeometry.build(definition.style, _materials_for(definition.style))
	marker.add_child(geometry)

	# Orient toward the island centre so landmarks face the player's approach.
	var facing: float = atan2(position.x, position.z) + PI
	marker.rotation.y = facing
	return marker


## Per-style palette. Colour lives here rather than in `PoiGeometry` so a mod can place
## the same shape in its own colours by supplying a factory that passes a different
## dictionary — and so the built-in shapes keep readable defaults when it does not.
func _materials_for(style: StringName) -> Dictionary:
	var stone := PoiGeometry.standard_material(Color(0.46, 0.45, 0.42))
	var wood := PoiGeometry.standard_material(Color(0.31, 0.21, 0.13))
	match style:
		&"crystal":
			return {
				"stone": PoiGeometry.standard_material(Color(0.34, 0.35, 0.4)),
				"crystal": PoiGeometry.emissive_material(Color(0.35, 0.75, 1.0), 2.4),
			}
		&"ruins":
			return {
				"stone": PoiGeometry.standard_material(Color(0.52, 0.5, 0.45)),
				"wood": wood,
			}
		&"campsite":
			return {
				"wood": wood,
				"cloth": PoiGeometry.standard_material(Color(0.56, 0.31, 0.23)),
				"ember": PoiGeometry.emissive_material(Color(1.0, 0.55, 0.2), 3.0),
			}
		&"watchtower":
			return {"stone": stone, "wood": wood}
	return {"stone": stone}
