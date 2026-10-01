extends Node3D
class_name InteractionProbe
## Detects the nearest interactable in front of the player and owns the input
## handoff, so interaction targets never hard-code a node path.
##
## Detection is a distance test against the `interactable` group with a facing
## check rather than a physics raycast: a landmark's collider can sit anywhere,
## and gameplay should not depend on a collision layer being right.

@export var player_path: NodePath = ^".."
@export var reach: float = 4.2
@export var facing_dot_threshold: float = 0.15
@export var probe_interval: float = 0.1

var current: Interactable = null

var _player: Player = null
var _elapsed: float = 0.0


func _ready() -> void:
	_player = get_node_or_null(player_path) as Player


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < probe_interval:
		return
	_elapsed = 0.0

	if GameState.mode != GameState.Mode.EXPLORING:
		_clear_focus()
		return

	var found: Interactable = _find_nearest()
	if found != current:
		_clear_focus()
		current = found
		if current != null:
			Events.interactable_focused.emit(current, current.prompt_text())


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(&"interact"):
		return
	if current == null or GameState.mode != GameState.Mode.EXPLORING:
		return
	current.interact(_player)
	get_viewport().set_input_as_handled()


func _find_nearest() -> Interactable:
	if _player == null:
		return null
	var origin: Vector3 = _player.global_position
	var facing: Vector3 = _player.facing_direction()
	var best: Interactable = null
	var best_distance: float = INF

	for node: Node in get_tree().get_nodes_in_group(&"interactable"):
		var interactable: Interactable = node as Interactable
		if interactable == null or not interactable.can_interact(_player):
			continue
		var offset: Vector3 = interactable.global_position - origin
		var distance: float = offset.length()
		if distance > reach:
			continue
		var flat_offset := Vector3(offset.x, 0.0, offset.z)
		if flat_offset.length_squared() > 0.01 and flat_offset.normalized().dot(facing) < facing_dot_threshold:
			continue
		if distance < best_distance:
			best_distance = distance
			best = interactable
	return best


func _clear_focus() -> void:
	if current != null:
		Events.interactable_unfocused.emit(current)
		current = null
