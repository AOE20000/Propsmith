extends Node
## Do the proportion sliders now resolve to real bones?
##
## Measured before the fix: **0 of 21** targets present, because
## `DEFORM_GROUPS` named Rigify bones (`spine`, `thigh.L`) and the shipped
## figure is VRM (`Spine`, `LeftUpperLeg`). Every slider was a silent no-op.
## The groups now name *roles* and `resolve_role` maps a role onto whatever the
## loaded rig calls that bone, so this re-runs the same count through the new
## path.
var _skel: Skeleton3D

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(load("res://src/boot/startup.tscn").instantiate())
	Events.world_ready.connect(_w)

func _w(_x: Node3D) -> void:
	var p := get_tree().get_first_node_in_group(&"player") as Player
	var m := p.get_node_or_null("PlayerModel") as Node3D
	for n: Node in m.find_children("*", "Skeleton3D", true, false):
		_skel = n as Skeleton3D
		break
	var conv: StringName = CharacterAppearance.detect_rig_convention(_skel)
	print("[v2] rig convention detected: %s" % String(conv))
	var grand_total := 0
	var grand_hit := 0
	for id: StringName in CharacterAppearance.DEFORM_GROUPS:
		var group: Dictionary = CharacterAppearance.DEFORM_GROUPS[id]
		var hits: Array[String] = []
		var total := 0
		for op: String in ["scale_y", "scale_x", "scale_xz"]:
			for role: String in group.get(op, []):
				total += 1
				var name: String = CharacterAppearance.resolve_role(_skel, role, conv)
				if not name.is_empty():
					hits.append("%s→%s" % [role, name])
		grand_total += total
		grand_hit += hits.size()
		print("[v2] %-16s %d/%d resolved%s" % [
			String(id), hits.size(), total,
			"" if hits.is_empty() else "  " + str(hits)])
	print("[v2] TOTAL %d/%d  (was 0/21 before the fix)" % [grand_hit, grand_total])
	# And the foot anchor the re-anchoring now looks for.
	for role: String in ["LeftFoot", "RightFoot"]:
		print("[v2] anchor role %-10s → %s" % [
			role, CharacterAppearance.resolve_role(_skel, role, conv)])
	get_tree().quit(0)
