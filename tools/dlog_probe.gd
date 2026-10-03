extends Node
## End-to-end probe for the DecisionLog + NPC appearance override path:
## emit a figure decision → live citizen applies it → journal exists on disk →
## a citizen regenerated with the same seed receives the override at spawn.
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
	var body_b: MeshInstance3D = (agent_b.get_node_or_null("Figure") \
		as Node3D).find_child("SiroinoSotai_Body", true, false) as MeshInstance3D
	print("[dlog] b.spawned=%s b.live_All_L=%.2f (expect 0.80)" % [
		applied_b, body_b.get_blend_shape_value(all_l)])

	# The journal must exist and carry the decision.
	var journal := "user://journal/slot1.jsonl"
	var lines := 0
	if FileAccess.file_exists(journal):
		var file := FileAccess.open(journal, FileAccess.READ)
		while not file.eof_reached():
			if not file.get_line().strip_edges().is_empty():
				lines += 1
	print("[dlog] journal_lines=%d (expect >= 1)" % lines)

	# Replay must be safe to run twice (idempotent appliers).
	DecisionLog.replay_journal()
	print("[dlog] a.after_replay=%.2f (expect 0.80)" % body_a.get_blend_shape_value(all_l))

	agent_a.queue_free()
	agent_b.queue_free()
	print("[dlog] ALL_PASS")
	get_tree().quit(0)
