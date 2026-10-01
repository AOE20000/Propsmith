extends Node
class_name Damageable
## The contract for "this can be damaged".
##
## Combat is intentionally interface-only: the core ships this base class and a
## reference `HealthComponent`, and nothing else. A game (or a mod) supplies the
## balance — armour curves, shields, resistances, death behaviour — by extending
## this class or by providing its own node that exposes the same two methods.
##
## A hitbox looks for a `Damageable` on the collider or its ancestors, so any node
## in the tree can be made damageable without registering anywhere.

## Set to false to become temporarily invulnerable (dodge frames, cutscenes).
@export var vulnerable: bool = true
## Multiplier applied to incoming damage before `apply_damage` sees it.
@export var incoming_multiplier: float = 1.0

## Emitted after damage was accepted. `applied` is post-multiplier.
signal damaged(info: DamageInfo, applied: float)
## Emitted when the recipient considers itself defeated.
signal defeated(killer: Node)


## Return false to reject a hit outright (immunity, already dead, out of range).
## `DamageInfo` is read-only by convention; copy it if a reaction must modify it.
func can_receive_damage(_info: DamageInfo) -> bool:
	return vulnerable and incoming_multiplier > 0.0


## Apply a hit. Implementations own their own state and must be idempotent for a
## repeated call with the same `info` if they implement hit deduplication.
func apply_damage(_info: DamageInfo) -> float:
	return 0.0


## Current fraction of health in 0..1, or -1 when the concept does not apply.
## The HUD uses this for health bars and hides them when it sees -1.
func health_fraction() -> float:
	return -1.0


func is_defeated() -> bool:
	return false


## Find the nearest `Damageable` at or above `node`. This is the lookup a hitbox
## uses, and the reason damageable targets need no registration.
static func find_on(node: Node) -> Damageable:
	var current: Node = node
	while current != null:
		if current is Damageable:
			return current
		current = current.get_parent()
	return null
