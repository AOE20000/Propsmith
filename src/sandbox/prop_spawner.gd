extends Node
class_name PropSpawner
## Owns the session's spawned props, registered as the `prop_spawner` service.
##
## Everything the sandbox creates lives under one `Props` container in the world,
## so tearing the world down takes the props with it. The spawner also keeps the
## undo stack: every spawn is one undoable operation, and a removal erases any
## stack entries pointing at the removed node, so undo can never resurrect a
## deleted prop.
##
## Props are deliberately NOT persisted: like vehicles and pedestrians they are
## session content. (The duplicator's blueprint saves in P1 are the persistence
## story for constructions.)

var _container: Node3D = null
var _undo_stack: Array[Node] = []


## Bind to the world's prop container. Called after each map build.
func setup(container: Node3D) -> void:
	_container = container
	_undo_stack.clear()


## Instantiate a prop by catalog id at `at`, facing `yaw`. Returns the body, or
## null when the id is unknown or a factory misbehaves — both are reported, not
## silent, because a menu button that does nothing is a bug report waiting.
func spawn(prop_id: StringName, at: Vector3, yaw: float = 0.0) -> RigidBody3D:
	if _container == null:
		push_warning("PropSpawner: no world container bound; call setup() after the map builds")
		return null
	var definition: Dictionary = PropCatalog.find(prop_id)
	if definition.is_empty():
		push_warning("PropSpawner: unknown prop id '%s'" % prop_id)
		return null
	var factory: Callable = definition.get("factory", Callable())
	if not factory.is_valid():
		push_warning("PropSpawner: prop '%s' has no valid factory" % prop_id)
		return null
	var produced: Variant = factory.call()
	if not (produced is RigidBody3D):
		push_warning("PropSpawner: prop '%s' factory must return a RigidBody3D (got %s)" % [
			prop_id, type_string(typeof(produced)),
		])
		return null
	var prop: RigidBody3D = produced
	# The catalog id rides in metadata, not in the node name: Godot silently
	# renames same-named siblings, so a name-derived id would corrupt the
	# duplicator the moment two crates exist.
	prop.set_meta(&"prop_id", prop_id)
	prop.name = "Prop_%s" % prop_id
	_container.add_child(prop)
	prop.global_position = at
	prop.rotation.y = yaw
	_undo_stack.append(prop)
	Events.prop_spawned.emit(prop, prop_id)
	return prop


## Pop the last spawn and delete it.
func undo() -> bool:
	while not _undo_stack.is_empty():
		var node: Node = _undo_stack.pop_back()
		if is_instance_valid(node):
			var prop_id: StringName = node.get_meta(&"prop_id", &"")
			node.queue_free()
			Events.prop_removed.emit(prop_id)
			return true
	return false


## Delete a specific prop (the wrench's remove action). Also erased from the
## undo stack so undo can never resurrect it.
func remove(prop: Node) -> void:
	if prop == null or not is_instance_valid(prop):
		return
	_undo_stack.erase(prop)
	var prop_id: StringName = prop.get_meta(&"prop_id", &"")
	prop.queue_free()
	Events.prop_removed.emit(prop_id)


## Delete every spawned prop (the spawn menu's "clear" button).
func clear_all() -> void:
	for node: Node in _undo_stack:
		if is_instance_valid(node):
			node.queue_free()
	_undo_stack.clear()


func count() -> int:
	return _undo_stack.size()


func describe() -> String:
	return "props=%d" % _undo_stack.size()
