extends Node3D
class_name TourStop
## One stop on the guided tour: a trigger volume plus the card copy and the
## check that lights it up.
##
## Built entirely in code (the project's rule for scenes) and parented to the
## tour service rather than the map: the map declares *where* a stop stands
## (positions belong to the ground plan, like the decor zones), while the tour
## owns what the stop means and how it is judged. A mod adding a stop adds one
## object through `ModContext` instead of editing a map.

## Fired when a player body enters the trigger — the tour uses it to show the
## hint card, not to judge completion (a demonstration may be finished from
## outside the marker, which is friendlier than pinning the player inside it).
signal entered(stop: TourStop)
signal exited(stop: TourStop)

var stop_id: StringName = &""
var display_name: String = ""
## The hint card's main line (game-facing copy).
var hint: String = ""
## What the stop asks the player to do, shown under the hint.
var requirement: String = ""
## Returns true once the stop's demonstration has been performed. An invalid
## Callable means "arrival is enough".
var checker: Callable = Callable()
var radius: float = 4.0

var _area: Area3D = null


## Wire up the trigger volume. Split from construction so the owner can set the
## fields first and the node can be placed before the volume exists.
func setup() -> void:
	var area := Area3D.new()
	area.name = "Trigger"
	# Monitor only: the stop listens for players, it is not itself collidable.
	area.collision_layer = 0
	area.collision_mask = 1
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	shape.shape = sphere
	area.add_child(shape)
	add_child(area)
	area.body_entered.connect(_on_body_entered)
	area.body_exited.connect(_on_body_exited)
	_area = area


## Whether a player body is inside the marker right now — used by arrival stops
## ("walk to the exit platform") and by the hint card.
func contains_player() -> bool:
	if _area == null:
		return false
	for body: Node3D in _area.get_overlapping_bodies():
		if body.is_in_group(&"player"):
			return true
	return false


func _on_body_entered(body: Node3D) -> void:
	if body.is_in_group(&"player"):
		entered.emit(self)


func _on_body_exited(body: Node3D) -> void:
	if body.is_in_group(&"player"):
		exited.emit(self)


## Satisfied by default when no checker was supplied (a plain "walk here" stop).
func is_satisfied() -> bool:
	if not checker.is_valid():
		return true
	return bool(checker.call())
