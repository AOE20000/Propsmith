extends Node
class_name Attacker
## The contract for "this can deal damage".
##
## Mirrors `Damageable` on the other side of the exchange. The core never assumes
## how an attack is aimed, animated, or gated — only that it can be started, can
## refuse to start, and reports when it finishes. A mod-provided weapon, a turret,
## or a scripted trap all satisfy the same interface, so the HUD and the player
## controller can drive any of them.

signal attack_started(attack_id: StringName)
signal attack_finished(attack_id: StringName)

## Identifier of the attack currently running, or &"" when idle.
var active_attack: StringName = &""
var _cooldown_remaining: float = 0.0

## Set while an attack is in progress; used to gate movement and animation.
var _busy: bool = false


## Begin an attack. Returns false when the attacker cannot act (cooldown, dead,
## no target) so callers can fall through to something else.
func try_attack(_attack: AttackData) -> bool:
	return false


func is_attacking() -> bool:
	return _busy


func cooldown_remaining() -> float:
	return _cooldown_remaining


## Cancel without finishing: used on death, stun, or mode change.
func cancel_attack() -> void:
	_finish_attack()


func _begin_attack(attack: AttackData) -> void:
	_busy = true
	active_attack = attack.attack_id
	Events.attack_started.emit(self, attack)
	attack_started.emit(attack.attack_id)


func _finish_attack() -> void:
	if not _busy:
		return
	var finished_id: StringName = active_attack
	_busy = false
	active_attack = &""
	Events.attack_finished.emit(self, null)
	attack_finished.emit(finished_id)


func _tick_cooldown(delta: float) -> void:
	_cooldown_remaining = maxf(_cooldown_remaining - delta, 0.0)
