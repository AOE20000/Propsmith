extends Area3D
class_name Hitbox3D
## The damaging half of a hit. Enabled and disabled by an `Attacker` for the
## active frames of a swing.
##
## Deduplication is per-activation, not per-frame: opening the hitbox clears the
## "already hit" set, so a multi-frame swing lands once per target while two
## separate swings both land. Damage itself is always delivered through
## `Damageable`, so this node never needs to know what it is hitting.

## Base damage before any `DamageInfo` modifiers.
@export var damage: float = 12.0
@export var damage_type: StringName = &"physical"
## The node credited as the source; defaults to the owner of this hitbox.
@export var source_node: Node = null
## Knockback impulse forwarded to the target through `DamageInfo.tags`.
@export var knockback: float = 2.5
## Set false to keep the hitbox active on `_ready` (traps, hazards).
@export var start_disabled: bool = true

signal hit_landed(target: Node, applied: float)

var _already_hit: Dictionary = {}


func _ready() -> void:
	collision_layer = 0
	collision_mask = 1
	monitoring = true
	monitorable = false
	area_entered.connect(_on_area_entered)
	body_entered.connect(_on_body_entered)
	if start_disabled:
		deactivate()


## Clear the dedup set and start detecting. Call once per swing.
func activate() -> void:
	_already_hit.clear()
	monitoring = true
	set_deferred("monitoring", true)


func deactivate() -> void:
	monitoring = false
	set_deferred("monitoring", false)


## Deliver a hit to one node, resolving its `Damageable` and any `Hurtbox3D`.
func strike(target: Node, hit_position: Vector3, direction: Vector3) -> float:
	if target == null or not is_instance_valid(target):
		return 0.0
	if _is_self(target):
		return 0.0

	var key: int = target.get_instance_id()
	if _already_hit.has(key):
		return 0.0
	_already_hit[key] = true

	var hurtbox: Hurtbox3D = _find_hurtbox(target)
	var damageable: Damageable = null
	if hurtbox != null:
		damageable = hurtbox.damageable()
	if damageable == null:
		damageable = Damageable.find_on(target)
	if damageable == null:
		return 0.0

	var info := DamageInfo.create(damage, damage_type, source_node if source_node != null else owner, target, hit_position, direction)
	info.tags["knockback"] = knockback
	if hurtbox != null:
		info.multiplier *= hurtbox.damage_multiplier
		info.tags["hurtbox"] = hurtbox.name

	if not damageable.can_receive_damage(info):
		return 0.0

	Events.damage_requested.emit(info)
	var applied: float = damageable.apply_damage(info)
	Events.damage_applied.emit(info, target)
	hit_landed.emit(target, applied)
	return applied


func _on_body_entered(body: Node3D) -> void:
	if not monitoring:
		return
	var direction: Vector3 = (body.global_position - global_position).normalized()
	strike(body, body.global_position, direction)


func _on_area_entered(area: Area3D) -> void:
	if not monitoring:
		return
	var hurtbox: Hurtbox3D = area as Hurtbox3D
	if hurtbox == null:
		return
	var target: Node = hurtbox.owner_node()
	if target == null:
		return
	var direction: Vector3 = (area.global_position - global_position).normalized()
	strike(target, area.global_position, direction)


func _is_self(node: Node) -> bool:
	var self_root: Node = owner if owner != null else self
	var current: Node = node
	while current != null:
		if current == self_root or current == self:
			return true
		current = current.get_parent()
	return false


func _find_hurtbox(node: Node) -> Hurtbox3D:
	var current: Node = node
	while current != null:
		if current is Hurtbox3D:
			return current
		current = current.get_parent()
	return null
