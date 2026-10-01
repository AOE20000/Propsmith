extends Damageable
class_name HealthComponent
## Reference damageable implementation. The core ships this so the world is
## playable, and a game or mod replaces it when it needs armour, shields,
## resistances, or a different death model.
##
## Deliberately small: health, invulnerability window, defeat. Everything else
## belongs in an implementation that knows the game's rules.

@export var max_health: float = 100.0
@export var current_health: float = 100.0
## Seconds of invulnerability granted after each accepted hit.
@export var invulnerability_time: float = 0.0
## Destroy the owning node on defeat instead of only reporting it.
@export var free_on_defeat: bool = false

var _invulnerable_until_ms: int = 0
var _defeated: bool = false


func _ready() -> void:
	if current_health <= 0.0:
		current_health = max_health


func can_receive_damage(info: DamageInfo) -> bool:
	if _defeated or not vulnerable or incoming_multiplier <= 0.0:
		return false
	if info != null and info.total() <= 0.0:
		return false
	return Time.get_ticks_msec() >= _invulnerable_until_ms


func apply_damage(info: DamageInfo) -> float:
	if not can_receive_damage(info):
		return 0.0
	var applied: float = info.total() * incoming_multiplier
	current_health = maxf(current_health - applied, 0.0)
	if invulnerability_time > 0.0:
		_invulnerable_until_ms = Time.get_ticks_msec() + int(invulnerability_time * 1000.0)

	damaged.emit(info, applied)
	if current_health <= 0.0:
		_defeat(info.source)
	return applied


func heal(amount: float) -> float:
	var before: float = current_health
	current_health = minf(current_health + maxf(amount, 0.0), max_health)
	return current_health - before


func health_fraction() -> float:
	if max_health <= 0.0:
		return -1.0
	return clampf(current_health / max_health, 0.0, 1.0)


func is_defeated() -> bool:
	return _defeated


func _defeat(killer: Node) -> void:
	if _defeated:
		return
	_defeated = true
	defeated.emit(killer)
	Events.combatant_died.emit(owner if owner != null else self, killer)
	if free_on_defeat:
		var host: Node = owner if owner != null else self
		host.queue_free()


func serializable() -> Dictionary:
	return {"health": current_health, "defeated": _defeated}


func restore(data: Dictionary) -> void:
	current_health = float(data.get("health", max_health))
	_defeated = bool(data.get("defeated", false))
