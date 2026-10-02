extends ModBase
## Reference mod. It touches every extension point the core exposes, so it doubles
## as living documentation for the modding guide in `docs/MODDING.md`:
##
##   - `_on_world_populate`   direct world injection: the mod builds and places its
##                            own content once the map is ready
##   - `add_item_definition`  a new collectible — registered and validated, but note
##                            that the core has no inventory or pickup system yet, so
##                            this one has no visible effect (see docs/MODDING.md)
##   - `add_combat_provider`  an alternative attacker implementation
##   - `serialize/deserialize` persistence without touching the core save format
##   - `emit_mod_signal`      a channel other mods can listen on
##
## The island-era extension points (`add_poi_factory`, `add_prop_factory`,
## `add_terrain_modifier`) left with the island: their consumers — the scatter and
## landmark placers — were island systems. The registries still accept them (the
## contract is stable and asserted), but nothing consumes them on a city map, so
## this mod demonstrates the seam a city map actually has: placing content in
## `world_populate`.

const VISITS_KEY: String = "injections"

var _injection_count: int = 0


func _on_register() -> void:
	display_name = "灯塔与风化石"
	version = "2.0.0"
	author = "example"

	context.add_item_definition(&"lighthouse_log", {
		"display_name": "灯塔日志",
		"description": "灯塔守夜人留下的记录。",
		"stackable": false,
	})
	context.add_combat_provider(&"heavy_swing", _make_heavy_swing)

	log_message("已注册：重击攻击、日志道具")


func _on_world_populate(world: Node3D) -> void:
	# The map source has already found where the content clusters; anchoring to
	# that (not the world origin, which is a coordinate convention) and standing
	# a few metres aside keeps the beacon in the streets without occupying the
	# player's spawn point.
	var query: SurfaceQuery = Services.get_as(&"surface_query", &"SurfaceQuery") as SurfaceQuery
	if query == null or not query.is_ready():
		log_message("地表查询不可用，跳过灯塔注入")
		return
	var anchor: Vector3 = Vector3.ZERO
	var source: Variant = Services.get_service(&"map_source")
	if source is MapSource:
		anchor = (source as MapSource).spawn_anchor
	var marker := _make_lighthouse()
	marker.name = "LighthouseModMarker"
	# 24 m out: far enough that the third-person camera (a 5.4 m spring arm) can
	# never end up inside the shaft — the beacon is a pure visual mesh with no
	# collider, so the arm's collision response cannot save it.
	marker.position = query.sample_height(anchor + Vector3(24.0, 0.0, 0.0), 0.0)
	world.add_child(marker)

	_injection_count += 1
	emit_mod_signal(&"content_injected", {"node": "LighthouseModMarker"})
	log_message("世界已就绪，mod 内容已注入")


func _on_tick(_delta: float) -> void:
	# Kept empty on purpose: a mod should not burn per-frame budget unless it must.
	pass


func serialize() -> Dictionary:
	if _injection_count == 0:
		return {}
	return {VISITS_KEY: _injection_count}


func deserialize(data: Dictionary) -> void:
	_injection_count = int(data.get(VISITS_KEY, 0))
	if _injection_count > 0:
		log_message("读取到 %d 次内容注入记录" % _injection_count)


func _on_unload() -> void:
	log_message("已卸载（injections=%d）" % _injection_count)


func _on_collectible(_item_id: StringName, _amount: int) -> void:
	pass


## A tall tower with a rotating beam, built from primitives so the mod needs no
## assets of its own. Materials are local: the island-era `PoiGeometry` helpers
## went with the island, and a mod should not reach into core classes for paint.
func _make_lighthouse() -> Node3D:
	var root := Node3D.new()
	root.name = "Lighthouse"

	var stone := _flat_material(Color(0.82, 0.8, 0.76))
	var trim := _flat_material(Color(0.72, 0.26, 0.22))
	var beam := _emissive_material(Color(1.0, 0.94, 0.72), 4.0)

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

	# A rotating spotlight is enough to read as "lighthouse" without any animation
	# asset; in the city it reads as a beacon over the rooftops.
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


func _flat_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.85
	return material


func _emissive_material(color: Color, energy: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = energy
	return material


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


## Tiny helper node so the beacon turns. Shipped inside the mod rather than in the
## core, which is the point: behaviour a mod needs lives with the mod.
class LighthouseBeam extends Node3D:
	var pivot: Node3D = null

	func _process(delta: float) -> void:
		if pivot != null and is_instance_valid(pivot):
			pivot.rotate_y(delta * 0.35)
