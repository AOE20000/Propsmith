extends Node
## Multiplayer probe \u2014 HOST side. Run:
##   godot --headless --path . res://tools/enet_probe_host.tscn -- --port 24565
## Spawns a crate (journaled), hosts, and reports whether the joining peer's
## decision arrived and was applied. Writes a result JSON for the driver.

var _spawner: PropSpawner = null
var _transport: EnetTransport = null
var _client_decisions: int = 0
var _result_path: String = "res://vendor/enet_host_result.json"


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--port="):
			_result_path = _result_path.replace(".json", "_%s.json" % arg.trim_prefix("--port="))
	GameState.map_id = "probe_city"
	var container := Node3D.new()
	container.name = "Props"
	add_child(container)
	_spawner = PropSpawner.new()
	add_child(_spawner)
	_spawner.setup(container)
	var persistence := SandboxPersistence.new()
	add_child(persistence)
	persistence.setup(_spawner, ConstraintStore.new())

	_transport = EnetTransport.new()
	add_child(_transport)
	_transport.sandbox_persistence = persistence
	var port := 24565
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--port="):
			port = int(arg.trim_prefix("--port="))
	if not _transport.start_host(port):
		print("[enet-host] start_host failed")
		get_tree().quit(1)
		return

	# A prop spawned BEFORE the join: the client must receive it via catch-up.
	_spawner.spawn(&"crate", Vector3(1.0, 1.0, 0.0))

	DecisionLog.decision_applied.connect(func(kind: StringName, _payload: Dictionary) -> void:
		if kind == &"spawn_prop":
			_client_decisions += 1
	)
	# Report after a window long enough for join + catch-up + client decision.
	get_tree().create_timer(10.0).timeout.connect(_finish)


func _finish() -> void:
	var props := _spawner.count()
	var file := FileAccess.open(_result_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({
			"host": true,
			"client_decisions_applied": _transport.ingested_count,
			"props_on_host": props,
		}))
		file.close()
	print("[enet-host] result written: client_decisions=%d props=%d" % [_transport.ingested_count, props])
	get_tree().quit(0)
