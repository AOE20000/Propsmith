extends RefCounted
class_name PlayerScene
## Assembles the player in code instead of a hand-written `.tscn`.
##
## Rationale: a generated scene is reviewable as a diff, cannot drift from its
## script, and is verified by the headless smoke test. The node structure is the
## conventional one, so replacing this file with a designed scene later only means
## keeping the same node names.
##
## Shape:
##   Player (CharacterBody3D)
##   ├── CollisionShape3D
##   ├── Visual (Node3D) > MeshInstance3D
##   ├── CameraRig (Node3D) > SpringArm3D > Camera3D
##   ├── Weapon (BasicMeleeWeapon)
##   ├── InteractionProbe
##   └── AttackController

## Body dimensions are owned by `Player`, not restated here: the crouch collider and
## the stand-up clearance query both recompute from those constants, so duplicating
## them would let the built geometry drift from the runtime assumptions.
const PLAYER_HEIGHT: float = Player.BODY_HEIGHT
const PLAYER_RADIUS: float = Player.BODY_RADIUS
const EYE_HEIGHT: float = Player.EYE_HEIGHT


static func build() -> Player:
	var player := Player.new()
	player.name = "Player"

	var shape := CollisionShape3D.new()
	shape.name = "CollisionShape3D"
	var capsule := CapsuleShape3D.new()
	capsule.height = PLAYER_HEIGHT
	capsule.radius = PLAYER_RADIUS
	shape.shape = capsule
	shape.position = Vector3(0.0, PLAYER_HEIGHT * 0.5, 0.0)
	player.add_child(shape)

	player.add_child(_build_visual())
	player.add_child(_build_camera_rig())

	var weapon := _build_weapon()
	player.add_child(weapon)
	player.add_child(_build_interaction_probe())
	player.add_child(_build_attack_controller())

	SaveSystem.register_persistent(&"player", player.serializable, player.restore)
	return player


## A visible body. Deliberately a plain capsule with a facing marker rather than a
## character model: the world is a prototype, and a stand-in that reads clearly
## from behind is more useful than a placeholder mesh that hides the camera.
static func _build_visual() -> Node3D:
	var visual := Node3D.new()
	visual.name = "Visual"

	var body := MeshInstance3D.new()
	body.name = "Body"
	body.position = Vector3(0.0, PLAYER_HEIGHT * 0.5, 0.0)
	var capsule := CapsuleMesh.new()
	capsule.height = PLAYER_HEIGHT
	capsule.radius = PLAYER_RADIUS
	body.mesh = capsule
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.34, 0.52, 0.78)
	material.roughness = 0.55
	body.material_override = material
	visual.add_child(body)

	var head := MeshInstance3D.new()
	head.name = "Head"
	head.position = Vector3(0.0, PLAYER_HEIGHT - 0.12, 0.0)
	var sphere := SphereMesh.new()
	sphere.radius = 0.22
	sphere.height = 0.42
	sphere.radial_segments = 12
	sphere.rings = 6
	head.mesh = sphere
	var head_material := StandardMaterial3D.new()
	head_material.albedo_color = Color(0.86, 0.72, 0.6)
	head_material.roughness = 0.7
	head.material_override = head_material
	visual.add_child(head)

	# A nose cone makes the facing direction obvious without an animation rig.
	var facing := MeshInstance3D.new()
	facing.name = "Facing"
	facing.position = Vector3(0.0, EYE_HEIGHT, -PLAYER_RADIUS - 0.04)
	facing.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.06
	cone.height = 0.14
	cone.radial_segments = 8
	facing.mesh = cone
	var facing_material := StandardMaterial3D.new()
	facing_material.albedo_color = Color(0.95, 0.85, 0.4)
	facing.material_override = facing_material
	visual.add_child(facing)

	return visual


static func _build_camera_rig() -> CameraRig:
	var rig := CameraRig.new()
	rig.name = "CameraRig"
	rig.pivot_height = EYE_HEIGHT

	var arm := SpringArm3D.new()
	arm.name = "SpringArm3D"
	arm.spring_length = rig.arm_length
	arm.margin = 0.3
	arm.collision_mask = 1
	rig.add_child(arm)

	var camera := Camera3D.new()
	camera.name = "Camera3D"
	camera.fov = 72.0
	camera.current = true
	arm.add_child(camera)
	return rig


static func _build_weapon() -> BasicMeleeWeapon:
	var weapon := BasicMeleeWeapon.new()
	weapon.name = "Weapon"

	var attack := AttackData.new()
	attack.attack_id = &"melee_basic"
	attack.display_name = "挥击"
	attack.damage = 14.0
	attack.active_time = 0.18
	attack.cooldown = 0.55
	weapon.attack = attack

	var hitbox := Hitbox3D.new()
	hitbox.name = "Hitbox3D"
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = attack.radius
	shape.shape = sphere
	hitbox.add_child(shape)
	weapon.add_child(hitbox)
	hitbox.deactivate()
	return weapon


static func _build_interaction_probe() -> InteractionProbe:
	var probe := InteractionProbe.new()
	probe.name = "InteractionProbe"
	probe.reach = 4.2
	return probe


static func _build_attack_controller() -> PlayerAttackController:
	var controller := PlayerAttackController.new()
	controller.name = "AttackController"
	controller.attacker_path = ^"../Weapon"
	return controller
