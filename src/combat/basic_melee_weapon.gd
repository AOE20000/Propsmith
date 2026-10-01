extends Attacker
class_name BasicMeleeWeapon
## Reference attacker: a forward swing with an active window and a cooldown.
##
## This exists to prove the combat interface is sufficient, not to be the game's
## combat system. Balance, animation, combos, stamina costs and hit reactions are
## all deliberately absent — a game implements `Attacker` itself, or extends this
## and overrides `try_attack`.

@export var attack: AttackData = null
## Node that owns the hitbox; when empty a hitbox is created as a child.
@export var hitbox_path: NodePath = ^"Hitbox3D"
## Facing provider, usually the player. When empty the parent node is used.
@export var facing_source_path: NodePath = ^".."

var _hitbox: Hitbox3D = null
var _facing_source: Node3D = null
var _active_timer: float = 0.0


func _ready() -> void:
	_hitbox = get_node_or_null(hitbox_path) as Hitbox3D
	if _hitbox == null:
		_hitbox = _create_hitbox()
	_facing_source = get_node_or_null(facing_source_path) as Node3D
	if _facing_source == null:
		_facing_source = get_parent() as Node3D
	if attack == null:
		attack = AttackData.new()


func _process(delta: float) -> void:
	_tick_cooldown(delta)
	if not is_attacking():
		return
	_active_timer -= delta
	if _active_timer <= 0.0:
		if _hitbox != null:
			_hitbox.deactivate()
		_finish_attack()


func try_attack(attack_override: AttackData = null) -> bool:
	var chosen: AttackData = attack_override if attack_override != null else attack
	if chosen == null or is_attacking() or _cooldown_remaining > 0.0:
		return false

	if chosen.snap_to_target:
		_snap_toward_target(chosen)

	var source: Node = _facing_source if _facing_source != null else self
	if _hitbox != null:
		_hitbox.damage = chosen.damage
		_hitbox.damage_type = chosen.damage_type
		_hitbox.knockback = chosen.knockback
		_hitbox.source_node = source
		_hitbox.position = _hitbox_offset(chosen)
		_hitbox.activate()

	_active_timer = chosen.active_time
	_cooldown_remaining = chosen.cooldown
	_begin_attack(chosen)
	return true


## Nudge the user toward a nearby damageable, so a swing that looks like it
## should connect does. Widening this is how an action game implements aim assist.
func _snap_toward_target(chosen: AttackData) -> void:
	if _facing_source == null:
		return
	var origin: Vector3 = _facing_source.global_position
	var forward: Vector3 = -_facing_source.global_transform.basis.z
	var threshold: float = cos(deg_to_rad(chosen.snap_angle_degrees))
	var best: Node3D = null
	var best_distance: float = chosen.snap_max_distance

	for node: Node in get_tree().get_nodes_in_group(&"damageable"):
		var candidate: Node3D = node as Node3D
		if candidate == null or candidate == _facing_source:
			continue
		var offset: Vector3 = candidate.global_position - origin
		var distance: float = offset.length()
		if distance > best_distance or distance < 0.01:
			continue
		if offset.normalized().dot(forward) < threshold:
			continue
		best = candidate
		best_distance = distance

	if best == null:
		return
	var direction: Vector3 = best.global_position - origin
	direction.y = 0.0
	if direction.length_squared() < 0.01:
		return
	var target_yaw: float = atan2(direction.x, direction.z)
	_facing_source.rotation.y = lerp_angle(_facing_source.rotation.y, target_yaw, 0.65)


func _hitbox_offset(chosen: AttackData) -> Vector3:
	return Vector3(0.0, chosen.height_offset, -chosen.reach * 0.5)


func _create_hitbox() -> Hitbox3D:
	var hitbox := Hitbox3D.new()
	hitbox.name = "Hitbox3D"
	hitbox.damage = attack.damage if attack != null else 10.0
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = attack.radius if attack != null else 0.85
	shape.shape = sphere
	hitbox.add_child(shape)
	add_child(hitbox)
	return hitbox
