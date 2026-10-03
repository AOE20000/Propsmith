extends Node
class_name EnetTransport
## The ENet transport module for the DecisionLog \u2014 the first pluggable
## "sync method" (a later mod can register Nakama / Steam / WebRTC against the
## same seam: `DecisionLog.transport` + `broadcast(record)`).
##
## Topology: host-authoritative star. The host runs the world and is the only
## journal writer; clients apply what the host delivers and submit their own
## decisions for the host to authorise.
##
## Decision flow:
##   local record (either side) \u2192 DecisionLog.record \u2192 transport.broadcast:
##     host  \u2192 `receive_decision` to every client;
##     client \u2192 `submit_decision` to the host \u2192 host ingests (apply + journal)
##       and relays to every *other* client \u2014 the originator already applied
##       its own change locally, so it is excluded or props would double.
##
## Catch-up for late joiners: on request, the host sends its sandbox snapshot
## (props/constraints) plus its journal tail; the joiner deserializes the
## snapshot through its own SandboxPersistence and replays the tail through
## the registered appliers \u2014 the exact crash-recovery path, reused.
##
## Positions are *not* decisions: they stream over an unreliable channel and
## each peer renders remote players as capsules (a real figure + walk clip
## sync is the next milestone). Frequencies are modest; this is a co-op
## sandbox, not an shooter netcode.

const POSITION_INTERVAL: float = 1.0 / 12.0

signal sync_completed
signal peer_joined(peer_id: int)
signal peer_left(peer_id: int)

var is_host: bool = false
var active: bool = false

var _track_node: Node3D = null
var _position_accum: float = 0.0
var _avatars: Dictionary = {}
## The joiner-side persistence instance used for catch-up (set by the game).
var sandbox_persistence: SandboxPersistence = null
## How many peer-submitted decisions were ingested (probe/diagnostic metric).
var ingested_count: int = 0
var _pending_catchup: bool = false


## Start listening. The local DecisionLog stays the authority: it journals and
## its autosave keeps running.
func start_host(port: int) -> bool:
	var peer := ENetMultiplayerPeer.new()
	if peer.create_server(port, 8) != OK:
		push_error("EnetTransport: cannot listen on port %d" % port)
		return false
	multiplayer.multiplayer_peer = peer
	is_host = true
	active = true
	_mount_canonically()
	_hook_peer_signals()
	multiplayer.peer_connected.connect(func(id: int) -> void: print("[enet] peer connected: ", id))
	multiplayer.peer_disconnected.connect(func(id: int) -> void: print("[enet] peer disconnected: ", id))
	DecisionLog.transport = self
	print("[enet] hosting on port %d" % port)
	return true


## Join a host. The local DecisionLog becomes a client: no journal, no
## autosave \u2014 the host's snapshot and decisions define the world.
func join(address: String, port: int) -> bool:
	var peer := ENetMultiplayerPeer.new()
	if peer.create_client(address, port) != OK:
		push_error("EnetTransport: cannot reach %s:%d" % [address, port])
		return false
	multiplayer.multiplayer_peer = peer
	is_host = false
	active = true
	_pending_catchup = true
	_mount_canonically()
	_hook_peer_signals()
	multiplayer.connected_to_server.connect(func() -> void:
		print("[enet] connected to server")
		print("[enet] connection status: ", multiplayer.multiplayer_peer.get_connection_status()))
	multiplayer.connection_failed.connect(func() -> void: print("[enet] CONNECTION FAILED"))
	multiplayer.server_disconnected.connect(func() -> void: print("[enet] server disconnected"))
	DecisionLog.transport = self
	DecisionLog.set_client_mode()
	print("[enet] joining %s:%d" % [address, port])
	return true


func stop() -> void:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	active = false
	DecisionLog.transport = null
	DecisionLog.restore_local_mode()
	for avatar: Node in _avatars.values():
		avatar.queue_free()
	_avatars.clear()


## RPC delivery resolves the target node by its path from the scene root, so
## every peer must mount this transport at the *same* path — it re-parents
## itself to the tree root under a fixed name (deferred: re-parenting during
## _ready is unsafe).
func _mount_canonically() -> void:
	name = "NetTransport"
	if get_parent() == get_tree().root:
		return
	_reparent_to_root.call_deferred()


func _reparent_to_root() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var root := tree.root
	var parent := get_parent()
	if parent == null or parent == root:
		return
	parent.remove_child(self)
	root.add_child(self)


## The node whose transform streams to the other peers (the local player).
func track(node: Node3D) -> void:
	_track_node = node


func _hook_peer_signals() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)


func _on_peer_connected(peer_id: int) -> void:
	peer_joined.emit(peer_id)
	if is_host:
		# Late-join catch-up: snapshot + journal tail, before any live decision
		# can reach the new peer (reliable channel is ordered per peer).
		var payload := {
			"map_id": GameState.map_id,
			"sandbox": sandbox_persistence.snapshot_for_sync() if sandbox_persistence != null else {},
			"journal": DecisionLog.uncovered_records(),
		}
		print("[enet] sending catch-up to ", peer_id, " journal=", payload["journal"].size())
		_receive_catchup.rpc_id(peer_id, payload)
		print("[enet] catch-up sent")


func _on_peer_disconnected(peer_id: int) -> void:
	peer_left.emit(peer_id)
	_drop_avatar(peer_id)


## DecisionLog transport contract: called on the originating peer after it
## applied a decision locally.
func broadcast(record: Dictionary) -> void:
	if not active:
		return
	if is_host:
		_relay_to_others(1, record)
	else:
		_submit_decision.rpc_id(1, record)


@rpc("any_peer", "call_remote", "reliable")
func _submit_decision(record: Dictionary) -> void:
	if not is_host:
		return
	ingested_count += 1
	var sender := multiplayer.get_remote_sender_id()
	# Host ingests: apply, journal, then relay to the other clients.
	DecisionLog.ingest_remote(record)
	_relay_to_others(sender, record)


func _relay_to_others(sender_id: int, record: Dictionary) -> void:
	for peer_id: int in multiplayer.get_peers():
		if peer_id != sender_id:
			_receive_decision.rpc_id(peer_id, record)


@rpc("authority", "call_remote", "reliable")
func _receive_decision(record: Dictionary) -> void:
	DecisionLog.apply_record(record)


@rpc("authority", "call_remote", "reliable")
func _receive_catchup(payload: Dictionary) -> void:
	print("[enet] _receive_catchup arrived, pending=", _pending_catchup)
	if not _pending_catchup:
		return
	_pending_catchup = false
	if String(payload.get("map_id", "")) != GameState.map_id:
		push_error("EnetTransport: host map differs from ours \u2014 refusing catch-up")
		get_tree().quit(1)
		return
	sandbox_persistence.apply_sync_snapshot(payload.get("sandbox", {}) as Dictionary)
	for record: Variant in payload.get("journal", []):
		if record is Dictionary:
			DecisionLog.apply_record(record)
	print("[enet] catch-up applied")
	sync_completed.emit()


func _process(delta: float) -> void:
	if not active or _track_node == null:
		return
	_position_accum += delta
	if _position_accum < POSITION_INTERVAL:
		return
	_position_accum = 0.0
	var transform := _track_node.global_transform
	_sync_position.rpc(transform.origin, transform.basis.get_rotation_quaternion())


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _sync_position(origin: Vector3, facing: Quaternion) -> void:
	var sender := multiplayer.get_remote_sender_id()
	_update_avatar(sender, origin, facing)
	if is_host:
		# Relay so clients see each other through the host.
		for peer_id: int in multiplayer.get_peers():
			if peer_id != sender:
				_sync_position.rpc_id(peer_id, origin, facing)


## A simple capsule per remote peer; a synced figure replaces it later.
func _update_avatar(peer_id: int, origin: Vector3, facing: Quaternion) -> void:
	var avatar: Node3D = _avatars.get(peer_id)
	if avatar == null or not is_instance_valid(avatar):
		avatar = _make_avatar()
		_avatars[peer_id] = avatar
	avatar.global_position = origin
	avatar.global_transform.basis = Basis(facing)


func _make_avatar() -> Node3D:
	var root := Node3D.new()
	var mesh := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.height = 1.5
	capsule.radius = 0.26
	mesh.mesh = capsule
	mesh.position = Vector3(0.0, 0.75, 0.0)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.85, 0.55, 0.3)
	material.roughness = 0.8
	mesh.material_override = material
	root.add_child(mesh)
	add_child(root)
	return root


func _drop_avatar(peer_id: int) -> void:
	var avatar: Node3D = _avatars.get(peer_id)
	if avatar != null and is_instance_valid(avatar):
		avatar.queue_free()
	_avatars.erase(peer_id)
