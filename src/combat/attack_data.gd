extends Resource
class_name AttackData
## Parameters of one attack. Data, not behaviour: the same values drive the
## reference melee weapon, and a mod can ship its own `.tres` without code.

@export var attack_id: StringName = &"melee_basic"
@export var display_name: String = "挥击"
## Damage before the target's own multipliers.
@export var damage: float = 14.0
@export var damage_type: StringName = &"physical"
## Seconds the hitbox stays active.
@export var active_time: float = 0.18
## Seconds before another attack may start, measured from the start of this one.
@export var cooldown: float = 0.55
## Forward reach of the hitbox in metres.
@export var reach: float = 1.9
@export var radius: float = 0.85
@export var height_offset: float = 1.1
## Impulse forwarded to the target through `DamageInfo.tags`.
@export var knockback: float = 3.0
## When true the attacker turns toward the nearest damageable in front of it.
@export var snap_to_target: bool = true
@export var snap_angle_degrees: float = 55.0
@export var snap_max_distance: float = 3.4
