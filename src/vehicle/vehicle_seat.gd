extends Interactable
class_name VehicleSeat
## The driver's seat, expressed as an ordinary `Interactable`.
##
## This is the seam that makes boarding need no new systems at all: the player's
## existing probe already finds anything in the `interactable` group within reach,
## already shows its prompt, and already sends it the `interact` action. A vehicle
## therefore costs zero lines in the player, the HUD or the input map.
##
## Boarding and leaving are one interaction, so `prompt_text()` changes with
## occupancy instead of two interactables contending for the same key.

## Set by `Vehicle._ready`. Left nullable because a seat is a scene node and may
## exist for a frame before its parent is ready.
var vehicle: Vehicle = null


func prompt_text() -> String:
	if vehicle == null:
		return verb
	return vehicle.exit_verb if vehicle.is_occupied() else vehicle.enter_verb


## Offered when the seat is empty, or when the person asking is already the driver
## (so they can get out). A vehicle driven by somebody else is not offered — with a
## single local player that only becomes reachable once a mod adds a second driver,
## but the check is what keeps that case from being a surprise later.
func can_interact(player: Node = null) -> bool:
	if not super.can_interact(player):
		return false
	if vehicle == null:
		return false
	var driver: Node3D = vehicle.driver()
	return driver == null or driver == player


func interact(player: Node = null) -> void:
	super.interact(player)
	if vehicle == null:
		return
	var rider: Node3D = player as Node3D
	if rider == null:
		# A mod may drive the interaction from a script without a player, which the
		# `Interactable` contract allows; there is simply nothing to seat.
		return
	vehicle.toggle_occupant(rider)
