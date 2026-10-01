extends Area3D
class_name Hurtbox3D
## Optional marker for a body part that takes more or less damage: a head, a
## weak spot, an armoured shell.
##
## Purely additive. A `Hitbox3D` works against a bare `Damageable`; attaching a
## hurtbox only refines where the hit landed and how much it counted for.

## Scales incoming damage for hits that land inside this volume.
@export_range(0.05, 8.0, 0.05) var damage_multiplier: float = 1.0
## The damageable this hurtbox belongs to. When empty, the nearest ancestor
## `Damageable` is used, which is the common case for a body-part child node.
@export var damageable_path: NodePath = ^""


func _ready() -> void:
	collision_layer = 0
	collision_mask = 0
	monitoring = false
	monitorable = true


func damageable() -> Damageable:
	if not damageable_path.is_empty():
		return get_node_or_null(damageable_path) as Damageable
	return Damageable.find_on(self)


## The node a hitbox should treat as the target: the damageable when there is
## one, otherwise this hurtbox's owner.
func owner_node() -> Node:
	var resolved: Damageable = damageable()
	if resolved != null:
		return resolved
	return owner
