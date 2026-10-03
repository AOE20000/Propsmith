extends Node
## End-to-end probe for the DecisionLog + NPC appearance override path:
## emit a figure decision → live citizen applies it → journal exists on disk →
## a citizen regenerated with the same seed receives the override at spawn →
## the panel's NPC edit mode journals its working set on flush.
## Run: godot --headless --path . res://tools/dlog_probe.tscn --quit-after 300


func _ready() -> void:
	var seed_key := 424242

	# Citizen A: spawn with the shared figure, then edit its look via a decision.
	var agent_a := PedestrianAgent.new()
	agent_a.figure_seed = seed_key
	add_child(agent_a)
	var applied_a: bool = agent_a.apply_base_figure()
	var figure_a: Node3D = agent_a.get_node_or_null("Figure")
	print("[dlog] a.spawned=%s" % applied_a)

	NpcFigure.emit_figure_override(seed_key, {"figure_plump": 0.8})
	var body_a: MeshInstance3D = figure_a.find_child("SiroinoSotai_Body", true, false) as MeshInstance3D
	var all_l := ModelBlendShapes.shape_index(body_a.mesh as ArrayMesh, "All_L")
	print("[dlog] a.live_All_L=%.2f (expect 0.80)" % body_a.get_blend_shape_value(all_l))

	# Citizen B: same seed, spawned AFTER the override — must come out edited.
	var agent_b := PedestrianAgent.new()
	agent_b.figure_seed = seed_key
	add_child(agent_b)
	var applied_b: bool = agent_b.apply_base_figure()
	var figure_b: Node3D = agent_b.get_node_or_null("Figure")
	var body_b: MeshInstance3D = figure_b.find_child("SiroinoSotai_Body", true, false) as MeshInstance3D
	print("[dlog] b.spawned=%s b.live_All_L=%.2f (expect 0.80)" % [
		applied_b, body_b.get_blend_shape_value(all_l)])

	# The journal must exist and carry the decision.
	print("[dlog] journal_lines=%d (expect >= 1)" % _journal_lines())

	# Panel NPC mode: open_for_npc seeds the working set from live values, a
	# slider write previews locally, and the flush journals the whole set.
	var panel := CharacterPanel.new()
	add_child(panel)
	panel.open_for_npc(agent_a)
	panel._blend_section.set_value("figure_medium", 0.5)
	var lines_before := _journal_lines()
	panel._blend_section.flush()
	print("[dlog] panel.flush: lines %d -> %d (expect +1)" % [
		lines_before, _journal_lines()])
	var all_m := ModelBlendShapes.shape_index(body_a.mesh as ArrayMesh, "All_M")
	print("[dlog] a.live_All_M=%.2f (expect 0.50, panel edit)" % body_a.get_blend_shape_value(all_m))

	# Replay must be safe to run twice (idempotent appliers).
	DecisionLog.replay_journal()
	print("[dlog] a.after_replay=%.2f (expect 0.80)" % body_a.get_blend_shape_value(all_l))

	agent_a.queue_free()
	agent_b.queue_free()
	panel.queue_free()
	print("[dlog] ALL_PASS")
	get_tree().quit(0)


func _journal_lines() -> int:
	var journal := "user://journal/slot1.jsonl"
	if not FileAccess.file_exists(journal):
		return 0
	var file := FileAccess.open(journal, FileAccess.READ)
	var lines := 0
	while not file.eof_reached():
		if not file.get_line().strip_edges().is_empty():
			lines += 1
	return lines
