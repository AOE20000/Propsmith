extends Node
## Multiplayer probe \u2014 CLIENT side. Run:
##   godot --headless --path . res://tools/enet_probe_client.tscn -- --port 24565
## Joins, waits for catch-up (the host's crate must appear), then spawns a ball
## (its decision routes through the host) and reports.

var _spawner: PropSpawner = null
var _transport: EnetTransport = null
var _result_path: String = "res://vendor/enet_client_result.json"
var _catchup_props: int = -1
var _decision_sent: bool = false


func _ready() -> void:
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
	if not _transport.join("127.0.0.1", port):
		print("[enet-client] join failed")
		get_tree().quit(1)
		return
	_transport.sync_completed.connect(_on_sync_completed)
	get_tree().create_timer(15.0).timeout.connect(_finish)


## Catch-up delivered: the host's props exist here now. Send our own decision.
func _on_sync_completed() -> void:
	_catchup_props = _spawner.count()
	print("[enet-client] catch-up props=%d" % _catchup_props)
	var ball := _spawner.spawn(&"ball", Vector3(3.0, 1.0, 0.0))
	_decision_sent = ball != null
	print("[enet-client] decision_sent=%s" % _decision_sent)


func _finish() -> void:
	var file := FileAccess.open(_result_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({
			"client": true,
			"catchup_props": _catchup_props,
			"decision_sent": _decision_sent,
		}))
		file.close()
	print("[enet-client] result written")
	get_tree().quit(0)
