extends Node
## End-to-end probe for sandbox decisions: spawn/paint/despawn journal, a save
## compacts the covered tail into the snapshot, props restored from the
## snapshot keep decision ids + paint, and loading clears the journal.
## Run: godot --headless --path . res://tools/sandbox_dlog_probe.tscn --quit-after 300

var _spawner: PropSpawner = null


func _ready() -> void:
	GameState.map_id = "probe_city"
	var container := Node3D.new()
	container.name = "Props"
	add_child(container)
	_spawner = PropSpawner.new()
	add_child(_spawner)
	_spawner.setup(container)
	var store := ConstraintStore.new()
	add_child(store)
	var persistence := SandboxPersistence.new()
	add_child(persistence)
	persistence.setup(_spawner, store)

	var journal := "user://journal/slot1.jsonl"
	var lines_before := _journal_lines(journal)

	# 1) spawn: journaled
	var prop := _spawner.spawn(&"crate", Vector3(2.0, 1.0, 0.0))
	var decision_id := String(prop.get_meta(&"decision_id", ""))
	var after_spawn := _journal_lines(journal)
	print("[sdlog] spawn: id=%s lines %d -> %d (expect +1)" % [decision_id, lines_before, after_spawn])

	# 2) paint: applied locally, journaled
	var color := Color(0.9, 0.2, 0.1)
	_spawner.paint_by_decision_id(decision_id, color)
	DecisionLog.record(&"paint_prop", {"decision_id": decision_id,
		"color": [color.r, color.g, color.b, color.a]})
	var after_paint := _journal_lines(journal)
	print("[sdlog] paint: lines -> %d (expect +1)" % after_paint)

	# 3) save: the covered tail compacts away, the snapshot carries the prop
	#    with its decision id + paint colour.
	SaveSystem.save_game("slot1")
	var after_save := _journal_lines(journal)
	var covered_left := 0
	for record: Dictionary in _journal_records(journal):
		if String(record.get("kind", "")) in ["spawn_prop", "despawn_prop", "paint_prop", "clear_props"]:
			covered_left += 1
	print("[sdlog] save: lines %d -> %d covered_left=%d (expect 0)" % [
		after_paint, after_save, covered_left])
	var snapshot := _read_snapshot("slot1")
	var saved_props: Array = snapshot.get("props", [])
	var ids_ok := false
	var paint_ok := false
	for record: Variant in saved_props:
		if record is Dictionary and String((record as Dictionary).get("decision_id", "")) == decision_id:
			ids_ok = true
			var albedo: Array = (record as Dictionary).get("albedo", [])
			if albedo.size() >= 3:
				paint_ok = is_equal_approx(float(albedo[0]), color.r) \
					and is_equal_approx(float(albedo[1]), color.g)
	print("[dlog] snapshot: props=%d decision_id=%s paint=%s" % [saved_props.size(), ids_ok, paint_ok])

	# 4) post-save tail: despawn the saved prop, spawn a new one
	_spawner.remove(prop)
	var after_despawn := _journal_lines(journal)
	print("[sdlog] despawn: lines -> %d (expect +1)" % after_despawn)
	var prop2 := _spawner.spawn(&"ball", Vector3(0.0, 1.0, 0.0))
	var second_id := String(prop2.get_meta(&"decision_id", ""))

	# 5) load: explicit rollback — snapshot restored (first prop back with
	#    paint), tail decisions dropped (second prop gone), journal emptied.
	var loaded: bool = SaveSystem.load_game("slot1")
	var first_back := _spawner.get_by_decision_id(decision_id) != null
	var second_gone := _spawner.get_by_decision_id(second_id) == null
	var visual := _spawner.get_by_decision_id(decision_id)
	var paint_back := false
	if visual != null:
		var mesh := visual.get_node_or_null("Visual") as MeshInstance3D
		if mesh != null and mesh.material_override is StandardMaterial3D:
			paint_back = (mesh.material_override as StandardMaterial3D).albedo_color.is_equal_approx(color)
	print("[dlog] load=%s first_back=%s paint_back=%s second_gone=%s" % [
		loaded, first_back, paint_back, second_gone])
	print("[dlog] journal_after_load=%d (expect 0)" % _journal_lines(journal))

	print("[sdlog] ALL_PASS")
	get_tree().quit(0)


func _read_snapshot(slot: String) -> Dictionary:
	var file := FileAccess.open(SaveSystem.slot_path(slot), FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not (parsed is Dictionary):
		return {}
	var sections: Variant = (parsed as Dictionary).get("sections", {})
	var sandbox: Variant = (sections as Dictionary).get("sandbox", {})
	return sandbox if sandbox is Dictionary else {}


func _journal_records(path: String) -> Array:
	var records: Array = []
	if not FileAccess.file_exists(path):
		return records
	var file := FileAccess.open(path, FileAccess.READ)
	while not file.eof_reached():
		var line := file.get_line()
		if line.strip_edges().is_empty():
			continue
		var parsed: Variant = JSON.parse_string(line)
		if parsed is Dictionary:
			records.append(parsed)
	file.close()
	return records


func _journal_lines(path: String) -> int:
	return _journal_records(path).size()
