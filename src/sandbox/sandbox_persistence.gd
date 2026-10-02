extends Node
class_name SandboxPersistence
## The persistence half of the sandbox: props and constraints are *decisions*
## the player made, so they ride every save under the `sandbox` section.
##
## The round-trip is blueprint-shaped rather than state-shaped: a save records
## each prop's catalog id, transform and frozen flag, plus every constraint's
## kind, ends and rebuild parameters — and the restore re-runs the same
## factories the spawn menu uses. Physics poses (velocities, exact collision
## resolution) are deliberately not kept: reloading replays the decisions, not
## the debris.
##
## Citizens and mod NPCs are session content and are not persisted, matching
## the vehicle rule. The map-identity check in `SaveSystem` already refuses
## cross-map loads, so these blueprints can never land on the wrong world.

const SECTION_ID: StringName = &"sandbox"

var _spawner: PropSpawner = null
var _store: ConstraintStore = null


## Bind the sandbox services and register the section. Explicit rather than
## done in `_ready`: the test scene registers its own spawner/store instances,
## and a service-lookup here would silently bind whichever instance registered
## first — the classic "same service, wrong instance" trap.
func setup(spawner: PropSpawner, store: ConstraintStore) -> void:
	_spawner = spawner
	_store = store
	SaveSystem.register_persistent(SECTION_ID, serialize, deserialize)


func serialize() -> Dictionary:
	var props: Array = _spawner.serialize_props()
	# Prop index = position in the saved list; constraints reference them by it.
	# The instance id recorded per prop makes the mapping exact — no guessing
	# by id-plus-position when two crates exist.
	var index_of := func(body: Variant) -> int:
		if not (body is Node):
			return -1
		var wanted: int = (body as Node).get_instance_id()
		for index: int in props.size():
			if int((props[index] as Dictionary).get("instance", -1)) == wanted:
				return index
		return -1
	var constraints: Array = _store.serialize_constraints(index_of)
	return {"props": props, "constraints": constraints}


func deserialize(data: Dictionary) -> void:
	# Start from a clean slate: loading a save replays the blueprint, it does
	# not merge with whatever was spawned this session.
	_spawner.clear_all()
	var saved_props: Array = data.get("props", [])
	var nodes: Array[Node3D] = []
	for record: Variant in saved_props:
		if record is Dictionary:
			var prop: RigidBody3D = _spawner.restore_prop(record)
			nodes.append(prop)
	var saved_constraints: Array = data.get("constraints", [])
	for record: Variant in saved_constraints:
		if not (record is Dictionary):
			continue
		var entry: Dictionary = record
		var ai: int = int(entry.get("a", -1))
		var bi: int = int(entry.get("b", -1))
		if ai < 0 or ai >= nodes.size() or bi < 0 or bi >= nodes.size():
			continue
		var link: Node = _store.build_link(
			StringName(String(entry.get("kind", "weld"))), nodes[ai], nodes[bi],
			entry.get("extra", {}) as Dictionary,
		)
		if link != null:
			_store.register(link, nodes[ai], nodes[bi], StringName(String(entry.get("kind", "weld"))))
	Events.notify("沙盒已恢复：%d 道具 · %d 约束" % [nodes.size(), saved_constraints.size()], Events.NotifyLevel.INFO)
