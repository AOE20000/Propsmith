extends Node3D
class_name Interactable
## Contract for anything the player can press E on: a chest, a sign, a lever, a
## campfire, or a mod's own contraption.
##
## Nodes join the `interactable` group and appear to the probe automatically, so
## adding an interaction never means editing the player. Extend this class and
## override `prompt_text()` and `interact()`, or extend `Interactable2D`-style
## behaviour by composing: only the two methods below are the contract.

## Seconds before this can be used again. 0 means no cooldown.
@export var cooldown_seconds: float = 0.0
## When false the interactable is skipped by the probe (already looted, locked).
@export var enabled: bool = true
## Prompt verb shown in the HUD, e.g. "打开".
@export var verb: String = "交互"

var _cooldown_remaining: float = 0.0


func _ready() -> void:
	add_to_group(&"interactable")
	set_process(cooldown_seconds > 0.0)


func _process(delta: float) -> void:
	if _cooldown_remaining > 0.0:
		_cooldown_remaining = maxf(_cooldown_remaining - delta, 0.0)


## Whether the probe may offer this to the player right now.
func can_interact(_player: Node = null) -> bool:
	return enabled and _cooldown_remaining <= 0.0


## Short line shown next to the key hint.
func prompt_text() -> String:
	return verb


## Perform the interaction. Implementations must tolerate a null `player`, which
## happens when a mod drives the interaction from a script.
func interact(_player: Node = null) -> void:
	if cooldown_seconds > 0.0:
		_cooldown_remaining = cooldown_seconds


## Begin the cooldown without doing anything else; useful for implementations that
## override `interact` and call `super.interact(player)`.
func start_cooldown() -> void:
	_cooldown_remaining = cooldown_seconds
