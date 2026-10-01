extends Node
class_name PlayerAttackController
## Binds the attack input to whatever `Attacker` is equipped. The player script
## stays ignorant of combat: swapping in a modded attacker means changing this
## node's `attacker_path`, not editing movement code.

@export var attacker_path: NodePath = ^"../Weapon"
## Requests beyond this many per second are ignored, so a stuck key cannot
## machine-gun the attacker.
@export var max_requests_per_second: float = 6.0

var attacker: Attacker = null

var _request_budget: float = 0.0


func _ready() -> void:
	attacker = get_node_or_null(attacker_path) as Attacker
	if attacker == null:
		# Fall back to any Attacker under the player, so a mod can drop one in.
		attacker = _find_attacker(get_parent())
	if attacker == null:
		push_warning("PlayerAttackController: no Attacker found; attacks are disabled")


func _process(delta: float) -> void:
	_request_budget = minf(_request_budget + max_requests_per_second * delta, max_requests_per_second)


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(&"attack"):
		return
	if GameState.mode != GameState.Mode.EXPLORING:
		return
	if attacker == null or _request_budget < 1.0:
		return
	_request_budget -= 1.0
	if attacker.try_attack(null):
		get_viewport().set_input_as_handled()


func _find_attacker(root: Node) -> Attacker:
	if root == null:
		return null
	for child: Node in root.get_children():
		var found: Attacker = child as Attacker
		if found != null:
			return found
		var nested: Attacker = _find_attacker(child)
		if nested != null:
			return nested
	return null
