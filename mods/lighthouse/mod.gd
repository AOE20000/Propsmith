extends ModBase
## Reference mod. It touches every extension point the core exposes, so it doubles
## as living documentation for the modding guide in `docs/MODDING.md`:
##
##   - `add_poi_factory`      a new landmark with its own geometry
##   - `add_prop_factory`     a new scattered prop
##   - `add_terrain_modifier` a deterministic reshape of the heightfield
##   - `add_item_definition`  a new collectible — registered and validated, but note
##                            that the core has no inventory or pickup system yet, so
##                            this one has no visible effect (see docs/MODDING.md)
##   - `add_combat_provider`  an alternative attacker implementation
##   - `serialize/deserialize` persistence without touching the core save format
##   - `emit_mod_signal`      a channel other mods can listen on

const VISIT_COUNT_KEY: String = "visits"

var _visit_count: int = 0


func _on_register() -> void:
	display_name = "灯塔与风化石"
	version = "1.0.0"
	author = "example"

	context.add_poi_factory(&"lighthouse_point", "断崖灯塔", _make_lighthouse, 1.0)
	context.add_prop_factory(&"weathered_stone", _make_weathered_stone, 0.6, 38.0)
	context.add_item_definition(&"lighthouse_log", {
		"display_name": "灯塔日志",
		"description": "灯塔守夜人留下的记录。",
		"stackable": false,
	})
	context.add_combat_provider(&"heavy_swing", _make_heavy_swing)
	context.add_terrain_modifier(&"lighthouse_plateau", _raise_plateau, 40)

	# React to the game's own events instead of polling.
	Events.poi_discovered.connect(_on_poi_discovered)
	Events.collectible_picked_up.connect(_on_collectible)

	log_message("已注册：灯塔地标、风化石、地形改造、重击攻击、日志道具")


func _on_world_populate(world: Node3D) -> void:
	# Place a light near the island centre so the mod's effect is visible in a test
	# run without hunting for the landmark.
	var query: TerrainQuery = Services.get_as(&"terrain_query", &"TerrainQuery") as TerrainQuery
	if query == null:
		return
	var marker := Node3D.new()
	marker.name = "LighthouseModMarker"
	marker.position = query.sample_height(Vector3(0.0, 0.0, 0.0), 3.0)
	world.add_child(marker)
	log_message("世界已就绪，mod 内容已注入")


func _on_tick(_delta: float) -> void:
	# Kept empty on purpose: a mod should not burn per-frame budget unless it must.
	pass


func serialize() -> Dictionary:
	if _visit_count == 0:
		return {}
	return {VISIT_COUNT_KEY: _visit_count}


func deserialize(data: Dictionary) -> void:
	_visit_count = int(data.get(VISIT_COUNT_KEY, 0))
	if _visit_count > 0:
		log_message("读取到 %d 次地标发现记录" % _visit_count)


func _on_unload() -> void:
	log_message("已卸载（visit=%d）" % _visit_count)


func _on_poi_discovered(poi_id: StringName, display_name: String, _position: Vector3) -> void:
	_visit_count += 1
	emit_mod_signal(&"poi_seen", {"id": String(poi_id), "name": display_name})
	if poi_id == &"lighthouse_point":
		Events.notify("灯塔的灯又亮了一次", Events.NotifyLevel.SUCCESS)


func _on_collectible(_item_id: StringName, _amount: int) -> void:
	pass


## A tall tower with a rotating beam, built from primitives so the mod needs no
## assets of its own.
func _make_lighthouse() -> Node3D:
	var root := Node3D.new()
	root.name = "Lighthouse"

	var stone := PoiGeometry.standard_material(Color(0.82, 0.8, 0.76))
	var trim := PoiGeometry.standard_material(Color(0.72, 0.26, 0.22))
	var beam := PoiGeometry.emissive_material(Color(1.0, 0.94, 0.72), 4.0)

	var height: float = 16.0
	var shaft := CylinderMesh.new()
	shaft.top_radius = 1.5
	shaft.bottom_radius = 3.0
	shaft.height = height
	shaft.radial_segments = 12
	var shaft_node := MeshInstance3D.new()
	shaft_node.mesh = shaft
	shaft_node.material_override = stone
	shaft_node.position = Vector3(0.0, height * 0.5, 0.0)
	root.add_child(shaft_node)

	for band: int in 3:
		var ring := CylinderMesh.new()
		var ring_height: float = 0.5 + float(band) * 0.2
		ring.top_radius = 1.55 + float(band) * 0.5
		ring.bottom_radius = 1.6 + float(band) * 0.5
		ring.height = ring_height
		ring.radial_segments = 12
		var ring_node := MeshInstance3D.new()
		ring_node.mesh = ring
		ring_node.material_override = trim
		ring_node.position = Vector3(0.0, height * (0.35 + float(band) * 0.22), 0.0)
		root.add_child(ring_node)

	var lantern_room := CylinderMesh.new()
	lantern_room.top_radius = 2.2
	lantern_room.bottom_radius = 2.2
	lantern_room.height = 2.4
	lantern_room.radial_segments = 12
	var lantern_node := MeshInstance3D.new()
	lantern_node.mesh = lantern_room
	lantern_node.material_override = beam
	lantern_node.position = Vector3(0.0, height + 1.2, 0.0)
	root.add_child(lantern_node)

	var roof := CylinderMesh.new()
	roof.top_radius = 0.0
	roof.bottom_radius = 2.8
	roof.height = 2.0
	roof.radial_segments = 12
	var roof_node := MeshInstance3D.new()
	roof_node.mesh = roof
	roof_node.material_override = trim
	roof_node.position = Vector3(0.0, height + 3.4, 0.0)
	root.add_child(roof_node)

	# The beam pivots so the light sweeps the sea; a rotating spotlight is enough
	# to read as "lighthouse" without any animation asset.
	var pivot := Node3D.new()
	pivot.name = "BeamPivot"
	pivot.position = Vector3(0.0, height + 1.2, 0.0)

	var light := SpotLight3D.new()
	light.light_color = Color(1.0, 0.95, 0.78)
	light.light_energy = 8.0
	light.spot_range = 120.0
	light.spot_angle = 18.0
	light.rotation_degrees = Vector3(-18.0, 0.0, 0.0)
	pivot.add_child(light)
	root.add_child(pivot)

	var spinner := LighthouseBeam.new()
	spinner.name = "BeamSpinner"
	spinner.pivot = pivot
	root.add_child(spinner)

	return root


## A prop factory returns one Mesh; the scatter system handles instancing, so a
## mod never places thousands of nodes itself.
func _make_weathered_stone() -> Mesh:
	var primitive := SphereMesh.new()
	primitive.radius = 1.1
	primitive.height = 1.5
	primitive.radial_segments = 7
	primitive.rings = 4
	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, primitive.surface_get_arrays(0))
	return PropFactory.paint(array_mesh, 1.0, 0.62)


## An alternative attacker. A game swaps it in by overriding the `melee_basic`
## provider or by pointing its attack controller at this node.
func _make_heavy_swing() -> Node:
	var weapon := BasicMeleeWeapon.new()
	var attack := AttackData.new()
	attack.attack_id = &"heavy_swing"
	attack.display_name = "重击"
	attack.damage = 34.0
	attack.active_time = 0.32
	attack.cooldown = 1.35
	attack.reach = 2.4
	attack.radius = 1.25
	attack.knockback = 7.0
	weapon.attack = attack
	return weapon


## Deterministic reshape, called once per heightfield sample. `falloff` is the
## island mask, so the change fades out with the coast.
func _raise_plateau(world_x: float, world_z: float, height: float, falloff: float) -> float:
	const CENTRE := Vector2(120.0, -90.0)
	const RADIUS: float = 55.0
	var distance: float = Vector2(world_x, world_z).distance_to(CENTRE)
	if distance >= RADIUS:
		return height
	var influence: float = pow(1.0 - distance / RADIUS, 2.0)
	return height + influence * 9.0 * falloff


## Tiny helper node so the beacon turns. Shipped inside the mod rather than in the
## core, which is the point: behaviour a mod needs lives with the mod.
class LighthouseBeam extends Node3D:
	var pivot: Node3D = null

	func _process(delta: float) -> void:
		if pivot != null and is_instance_valid(pivot):
			pivot.rotate_y(delta * 0.35)
