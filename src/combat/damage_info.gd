extends Resource
class_name DamageInfo
## One damage event, decoupled from who deals it and who receives it.
##
## Everything a combat implementation needs travels in this object, so a melee
## swing, a trap, and a mod's custom damage-over-time all reach the target through
## the same path. Nothing here implies a health model: a target decides what
## "damage" means to it.

@export var amount: float = 10.0
## Free-form classifier: "physical", "fire", "fall", "custom:*".
@export var damage_type: StringName = &"physical"
## The node that produced the damage. May be null for environmental damage.
## Not exported: `@export` of a Node is only legal on Node-derived classes, and
## these are set through `create()` or directly by the caller.
var source: Node = null
## The node that receives it.
var target: Node = null
## World position of the hit, for effects and for hit-direction reactions.
@export var hit_position: Vector3 = Vector3.ZERO
## Direction the damage travels, normalized.
@export var direction: Vector3 = Vector3.ZERO
## Multiplier applied on top of `amount`, for critical hits and buffs.
@export var multiplier: float = 1.0
## Arbitrary per-implementation payload (status effects, knockback strength...).
@export var tags: Dictionary = {}


static func create(
	amount_value: float,
	damage_type_value: StringName = &"physical",
	source_node: Node = null,
	target_node: Node = null,
	hit_position_value: Vector3 = Vector3.ZERO,
	direction_value: Vector3 = Vector3.ZERO
) -> DamageInfo:
	var info := DamageInfo.new()
	info.amount = amount_value
	info.damage_type = damage_type_value
	info.source = source_node
	info.target = target_node
	info.hit_position = hit_position_value
	info.direction = direction_value.normalized()
	return info


func total() -> float:
	return amount * multiplier


## Description used by the HUD damage readout and by logs.
func describe() -> String:
	return "%s %.1f (%s)" % [damage_type, total(), source.name if source != null else "world"]
