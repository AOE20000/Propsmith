extends Node
class_name ConstraintStore
## Registry and caretaker for every sandbox constraint (welds, ropes, hinges).
## Registered as the `constraint_store` service.
##
## Two jobs beyond bookkeeping:
##   - **Lifetime linkage**: a joint referencing a freed body is a crash waiting
##     for its moment. The store listens for `prop_removed` (spawn undo, the
##     wrench's remove, clear-all) and frees every joint touching that body.
##   - **One container**: all joints live under the store node, so the tree view
##     stays readable and teardown is trivial.
##
## Rope visuals are registered alongside their joint and freed together.

var _container: Node3D = null
## `{joint, a, b, visual}` — a and b are the constrained bodies, kept so removal
## can match without dereferencing the (possibly freed) joint first.
var _records: Array[Dictionary] = []


## Bind to the world. Called after each map build; everything from the previous
## session is discarded with it.
func setup(container: Node3D) -> void:
	_container = container
	_records.clear()


## Register a constraint link (a Joint3D, or a self-contained node like
## `RopeVisual` that applies its own forces): parents it under the store's
## container and, for joints, wires node_a/node_b. That wiring must happen
## *after* the joint is in the tree — `get_path_to` needs a common ancestor —
## which is exactly why the store owns this step instead of the tools.
## `extra` carries the parameters a save needs to rebuild it (rope locals and
## rest length, hinge pivot and axis).
func register(link: Node, a: Node3D, b: Node3D, kind: StringName, extra: Dictionary = {}) -> void:
	if _container == null:
		push_warning("ConstraintStore: no container bound; call setup() after the map builds")
		link.queue_free()
		return
	_container.add_child(link)
	if link is Joint3D:
		var joint := link as Joint3D
		joint.node_a = joint.get_path_to(a)
		joint.node_b = joint.get_path_to(b)
	_records.append({"link": link, "a": a, "b": b, "kind": kind, "extra": extra})


## Build a constraint link from saved parameters — the single rebuilder shared
## by the tools (live clicks) and the persistence layer (restores). Returns the
## parentless link node; the caller registers it with the store.
func build_link(kind: StringName, a: Node3D, b: Node3D, extra: Dictionary) -> Node:
	match kind:
		&"weld":
			var weld := Generic6DOFJoint3D.new()
			weld.name = "Weld_%d" % (count() + 1)
			weld.position = extra.get("anchor", Vector3.ZERO)
			return weld
		&"rope":
			var rope := RopeVisual.new()
			rope.name = "Rope_%d" % (count() + 1)
			rope.length = float(extra.get("length", 1.0))
			rope.bind_ends(
				a, extra.get("local_a", Vector3.ZERO) as Vector3,
				b, extra.get("local_b", Vector3.ZERO) as Vector3,
			)
			return rope
		&"hinge":
			var hinge := HingeJoint3D.new()
			hinge.name = "Hinge_%d" % (count() + 1)
			var pivot: Vector3 = extra.get("pivot", Vector3.ZERO)
			var axis: Vector3 = (extra.get("axis", Vector3.UP) as Vector3).normalized()
			# The hinge turns around the joint's local Z: aim -Z along the saved
			# axis so a restored hinge spins the way it was placed.
			hinge.look_at_from_position(pivot, pivot + axis, Vector3.UP)
			return hinge
	push_warning("ConstraintStore: unknown constraint kind '%s'" % kind)
	return null


func count() -> int:
	return _records.size()


func describe() -> String:
	return "constraints=%d" % _records.size()


## Serialized form of every live constraint whose ends are both in the saved
## prop list. `index_of` maps a body to its saved index; ends that do not map
## (a mod NPC, a freed body) drop the record — a constraint with a dangling
## half is not a decision worth keeping.
func serialize_constraints(index_of: Callable) -> Array:
	var out: Array = []
	for record: Dictionary in _records:
		var a: Variant = record.get("a")
		var b: Variant = record.get("b")
		if not is_instance_valid(a) or not is_instance_valid(b):
			continue
		var ai: int = index_of.call(a)
		var bi: int = index_of.call(b)
		if ai < 0 or bi < 0:
			continue
		out.append({
			"kind": String(record.get("kind", &"weld")),
			"a": ai,
			"b": bi,
			"extra": record.get("extra", {}),
		})
	return out


func _process(_delta: float) -> void:
	# Continuous sweep rather than event-driven: props can also leave through
	# teardown or queue_free from anywhere, and a dangling constraint is a crash.
	# Records are read through Variant on purpose: a typed `Node` assignment of
	# a *freed* instance is itself a script error, which would abort this sweep
	# and leave the dangling reference in place forever.
	var doomed: Array[Dictionary] = []
	for record: Dictionary in _records:
		var a: Variant = record.get("a")
		var b: Variant = record.get("b")
		if not is_instance_valid(a) or not is_instance_valid(b):
			doomed.append(record)
	for record: Dictionary in doomed:
		_erase(record)


func _erase(record: Dictionary) -> void:
	var link: Variant = record.get("link")
	if is_instance_valid(link):
		(link as Node).queue_free()
	_records.erase(record)


## Every body connected to `prop` through a registered constraint — used by the
## duplicator (later) and by tools that want the "unfreeze the whole welded
## group" behaviour.
func neighbours_of(prop: Node3D) -> Array[Node3D]:
	var out: Array[Node3D] = []
	for record: Dictionary in _records:
		if not is_instance_valid(record.get("link")):
			continue
		var a: Variant = record.get("a")
		var b: Variant = record.get("b")
		if a == prop and is_instance_valid(b):
			out.append(b)
		elif b == prop and is_instance_valid(a):
			out.append(a)
	return out
