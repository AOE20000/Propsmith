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
## Persistence: every spawn/removal/paint is recorded as a DecisionLog entry
## (kinds `spawn_prop` / `despawn_prop` / `paint_prop`, keyed by a stable
## per-prop `decision_id`), and the save snapshot serialises the same records'
## end state — so a load = snapshot + journal-tail replay, and saving compacts
## the journal of snapshot-covered kinds. Citizens and mod NPCs are session
## content and stay out of both.

var _container: Node3D = null
var _undo_stack: Array[Node] = []
## decision_id -> prop node, for despawn/paint decisions and their replay.
var _by_decision_id: Dictionary = {}
var _decision_seq: int = 0

## Mobility context bound by the map source when a place table exists: citizens
## spawn with a seeded day plan. Without it they degrade to wandering.
var _mobility_candidates: Array[Dictionary] = []
var _mobility_cache: RouteCache = null
var _mobility_version: String = ""
var _mobility_finder: Callable = Callable()
var _mobility_patterns: Array[ActivityPattern] = []


## Bind to the world's prop container. Called after each map build.
func setup(container: Node3D) -> void:
	_container = container
	_undo_stack.clear()
	_by_decision_id.clear()
	DecisionLog.register_applier(&"spawn_prop", _apply_spawn_decision, true)
	DecisionLog.register_applier(&"despawn_prop", _apply_despawn_decision, true)
	DecisionLog.register_applier(&"paint_prop", _apply_paint_decision, true)
	DecisionLog.register_applier(&"reweight_prop", _apply_reweight_decision, true)


## Give spawned citizens a day plan. The map source calls this after loading its
## place table; without the binding, citizens wander instead — visible people,
## honestly unannotated.
func bind_mobility(
	candidates: Array[Dictionary],
	cache: RouteCache,
	version: String,
	finder: Callable,
	patterns: Array[ActivityPattern],
) -> void:
	_mobility_candidates = candidates
	_mobility_cache = cache
	_mobility_version = version
	_mobility_finder = finder
	_mobility_patterns = patterns


## Spawn a citizen: a pedestrian with a seeded day plan when mobility is bound,
## a wanderer when it is not. Counts toward undo like any spawned thing.
## `appearance` is `&"capsule"` (default) or `&"vrm"` — the shared base figure
## swaps in only when its imported scene exists, otherwise the capsule stands in.
func spawn_citizen(at: Vector3, seed_value: int, appearance: StringName = &"capsule") -> PedestrianAgent:
	if _container == null:
		push_warning("PropSpawner: no world container bound; call setup() after the map builds")
		return null
	var citizen := PedestrianAgent.new()
	citizen.name = "Citizen"
	citizen.set_meta(&"npc_kind", &"citizen")
	_container.add_child(citizen)
	citizen.global_position = at
	if appearance == &"vrm":
		citizen.apply_base_figure()
	if _mobility_cache != null and not _mobility_candidates.is_empty() and not _mobility_patterns.is_empty():
		var rng := RandomNumberGenerator.new()
		rng.seed = hash("citizen|%s|%d" % [_mobility_version, seed_value])
		var home: Dictionary = _mobility_candidates[rng.randi() % _mobility_candidates.size()]
		citizen.configure(
			_mobility_patterns[rng.randi() % _mobility_patterns.size()],
			_mobility_candidates, _mobility_cache, _mobility_version,
			home.get("position", at), seed_value, StringName(home.get("id", &"")),
			_mobility_finder,
		)
	else:
		citizen.configure_wander(at, seed_value)
	_undo_stack.append(citizen)
	Events.prop_spawned.emit(citizen, &"citizen")
	return citizen


## Spawn a mod-registered NPC by catalog id (kind `npc`). The factory builds the
## body; the spawner assigns wander or a day plan exactly as for citizens.
func spawn_npc(npc_id: StringName, at: Vector3, seed_value: int) -> CharacterBody3D:
	var definition: Dictionary = {}
	for entry: Dictionary in npc_entries():
		if StringName(entry.get("id", &"")) == npc_id:
			definition = entry
			break
	if definition.is_empty():
		push_warning("PropSpawner: unknown npc id '%s'" % npc_id)
		return null
	var factory: Callable = definition.get("factory", Callable())
	var produced: Variant = factory.call()
	if not (produced is CharacterBody3D):
		push_warning("PropSpawner: npc '%s' factory must return a CharacterBody3D (got %s)" % [
			npc_id, type_string(typeof(produced)),
		])
		return null
	var npc := produced as CharacterBody3D
	npc.set_meta(&"npc_kind", npc_id)
	_container.add_child(npc)
	npc.global_position = at
	if npc is PedestrianAgent:
		var agent := npc as PedestrianAgent
		if _mobility_cache != null and not _mobility_candidates.is_empty():
			var rng := RandomNumberGenerator.new()
			rng.seed = hash("npc|%s|%d" % [npc_id, seed_value])
			var home: Dictionary = _mobility_candidates[rng.randi() % _mobility_candidates.size()]
			agent.configure(
				_mobility_patterns[rng.randi() % _mobility_patterns.size()],
				_mobility_candidates, _mobility_cache, _mobility_version,
				home.get("position", at), seed_value, StringName(home.get("id", &"")),
				_mobility_finder,
			)
		else:
			agent.configure_wander(at, seed_value)
	_undo_stack.append(npc)
	Events.prop_spawned.emit(npc, npc_id)
	return npc


## NPC definitions for the spawn menu: the built-in citizen plus every
## mod-registered NPC, in one deterministic order.
func npc_entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = [{
		"id": &"citizen",
		"display_name": "市民",
		"category": "people",
		"factory": func() -> CharacterBody3D: return PedestrianAgent.new(),
	}]
	for entry: Variant in ModHost.content_ordered(&"npc"):
		if entry is Dictionary:
			out.append(entry)
	return out


## Instantiate a prop by catalog id at `at`, facing `yaw`. Returns the body, or
## null when the id is unknown or a factory misbehaves — both are reported, not
## silent, because a menu button that does nothing is a bug report waiting.
func spawn(prop_id: StringName, at: Vector3, yaw: float = 0.0) -> RigidBody3D:
	var decision_id := _next_decision_id()
	var prop := _spawn_raw(prop_id, at, yaw, decision_id)
	if prop == null:
		return null
	DecisionLog.record(&"spawn_prop", {
		"decision_id": decision_id,
		"id": String(prop_id),
		"position": [at.x, at.y, at.z],
		"yaw": yaw,
	})
	return prop


## The factory half shared by the interactive spawn, the journal applier and
## the snapshot restore: builds the prop, tags it with both ids and registers
## it. No decision is recorded here — that is the caller's choice.
func _spawn_raw(prop_id: StringName, at: Vector3, yaw: float, decision_id: String) -> RigidBody3D:
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
	prop.set_meta(&"decision_id", decision_id)
	prop.name = "Prop_%s" % prop_id
	_container.add_child(prop)
	prop.global_position = at
	prop.rotation.y = yaw
	_undo_stack.append(prop)
	_by_decision_id[decision_id] = prop
	Events.prop_spawned.emit(prop, prop_id)
	return prop


## Journal applier for `spawn_prop`: the payload is shaped like a snapshot
## record, so replay goes through exactly the restore path a load uses.
func _apply_spawn_decision(payload: Dictionary) -> void:
	restore_prop(payload)


## Journal applier for `despawn_prop`.
func _apply_despawn_decision(payload: Dictionary) -> void:
	remove_by_decision_id(String(payload.get("decision_id", "")))


## Journal applier for `reweight_prop`.
func _apply_reweight_decision(payload: Dictionary) -> void:
	var prop := get_by_decision_id(String(payload.get("decision_id", "")))
	if prop != null:
		prop.mass = float(payload.get("mass", prop.mass))


## Journal applier for `paint_prop`.
func _apply_paint_decision(payload: Dictionary) -> void:
	var color_values: Array = payload.get("color", [1.0, 1.0, 1.0])
	var color := Color(float(color_values[0]), float(color_values[1]),
		float(color_values[2]), float(color_values[3]) if color_values.size() > 3 else 1.0)
	paint_by_decision_id(String(payload.get("decision_id", "")), color)


## Recolour a prop by decision id (the paint applier). Mirrors the painter's
## material-duplicate discipline so the recolour stays local to the instance.
func paint_by_decision_id(decision_id: String, color: Color) -> bool:
	var prop := get_by_decision_id(decision_id)
	if prop == null:
		return false
	var visual := prop.get_node_or_null("Visual") as MeshInstance3D
	if visual == null:
		return false
	visual.material_override = (visual.material_override as Material).duplicate() \
		if visual.material_override != null else StandardMaterial3D.new()
	var material := visual.material_override as StandardMaterial3D
	if material == null:
		return false
	material.albedo_color = color
	return true


## Recolour 榜同款：按决策 ID 设置质量（paint applier 同型）。
func reweight_by_decision_id(decision_id: String, mass: float) -> bool:
	var prop := get_by_decision_id(decision_id)
	if prop == null:
		return false
	prop.mass = mass
	return true


## Despawn by decision id — the raw removal (no journal write); used by the
## despawn applier and by `remove`/`undo` after they record their decisions.
func remove_by_decision_id(decision_id: String) -> bool:
	var prop: Node = _by_decision_id.get(decision_id)
	if prop == null or not is_instance_valid(prop):
		return false
	remove(prop)
	return true


func get_by_decision_id(decision_id: String) -> RigidBody3D:
	var prop: Node = _by_decision_id.get(decision_id)
	if prop == null or not is_instance_valid(prop):
		return null
	return prop as RigidBody3D


func _next_decision_id() -> String:
	while true:
		var candidate := "p%06d" % (_decision_seq + 1)
		_decision_seq += 1
		if not _by_decision_id.has(candidate):
			return candidate
	_decision_seq += 1
	return "px_%d" % _decision_seq


## Pop the last spawn and delete it.
func undo() -> bool:
	while not _undo_stack.is_empty():
		var node: Node = _undo_stack.pop_back()
		if is_instance_valid(node):
			var prop_id: StringName = node.get_meta(&"prop_id", &"")
			var decision_id := String(node.get_meta(&"decision_id", ""))
			if decision_id != "":
				_by_decision_id.erase(decision_id)
				DecisionLog.record(&"despawn_prop", {"decision_id": decision_id})
			node.queue_free()
			Events.prop_removed.emit(prop_id)
			return true
	return false


## Delete a specific prop (the wrench's remove action). Also erased from the
## undo stack so undo can never resurrect it. Freed **immediately** — these
## calls come from input callbacks, and a same-frame constraint sweep must see
## the removal, not a pending queue_free.
func remove(prop: Node) -> void:
	if prop == null or not is_instance_valid(prop):
		return
	_undo_stack.erase(prop)
	var prop_id: StringName = prop.get_meta(&"prop_id", &"")
	var decision_id := String(prop.get_meta(&"decision_id", ""))
	if decision_id != "":
		_by_decision_id.erase(decision_id)
		DecisionLog.record(&"despawn_prop", {"decision_id": decision_id})
	prop.free()
	Events.prop_removed.emit(prop_id)


## Delete every spawned prop (the spawn menu's "clear" button). Freed
## immediately for the same reason `remove` is: the constraint store's sweep
## runs this frame and must see the removal.
func clear_all() -> void:
	for node: Node in _undo_stack:
		if is_instance_valid(node):
			node.free()
	_undo_stack.clear()
	_by_decision_id.clear()


## The spawn menu's "clear" button: one decision that empties the sandbox, so
## the journal (and any peer) sees the same wipe the local world just did.
func clear_all_recorded() -> void:
	DecisionLog.record(&"clear_props", {})
	clear_all()


## The serialized form of every spawned **prop** (id, transform, frozen state).
## Citizens and mod NPCs are session content, not decisions — identified by the
## absence of a `prop_id` meta — and are skipped here by design.
func serialize_props() -> Array:
	var out: Array = []
	for node: Node in _undo_stack:
		if not is_instance_valid(node) or not (node is RigidBody3D):
			continue
		var prop := node as RigidBody3D
		var prop_id: StringName = prop.get_meta(&"prop_id", &"")
		if prop_id == &"":
			continue
		var euler: Vector3 = prop.rotation
		var albedo: Array = []
		var mesh := node.get_node_or_null("Visual") as MeshInstance3D
		var mass_value: float = (node as RigidBody3D).mass
		if mesh != null and mesh.material_override is StandardMaterial3D:
			var c: Color = (mesh.material_override as StandardMaterial3D).albedo_color
			albedo = [c.r, c.g, c.b, c.a]
		out.append({
			"id": String(prop_id),
			"decision_id": String(node.get_meta(&"decision_id", "")),
			"albedo": albedo,
			"mass": mass_value,
			"instance": prop.get_instance_id(),
			"position": [prop.global_position.x, prop.global_position.y, prop.global_position.z],
			"rotation": [euler.x, euler.y, euler.z],
			"frozen": prop.freeze,
		})
	return out


## Rebuild one prop from a saved record. Returns the node so the constraint
## restorer can map saved indices back to live bodies.
func restore_prop(record: Dictionary) -> RigidBody3D:
	var prop_id := StringName(String(record.get("id", "")))
	var position_values: Array = record.get("position", [0.0, 1.0, 0.0])
	var rotation_values: Array = record.get("rotation", [0.0, 0.0, 0.0])
	var decision_id := String(record.get("decision_id", ""))
	if decision_id == "":
		decision_id = _next_decision_id()
	# The raw core, not spawn(): a snapshot restore is a compaction replay,
	# not a new decision.
	var prop := _spawn_raw(prop_id, Vector3(
		float(position_values[0]), float(position_values[1]), float(position_values[2])
	), float(rotation_values[1]), decision_id)
	if prop == null:
		return null
	prop.rotation = Vector3(
		float(rotation_values[0]), float(rotation_values[1]), float(rotation_values[2])
	)
	if record.has("mass"):
		prop.mass = float(record["mass"])
	var albedo_values: Array = record.get("albedo", [])
	if albedo_values.size() >= 3:
		var visual := prop.get_node_or_null("Visual") as MeshInstance3D
		if visual != null:
			visual.material_override = (visual.material_override as Material).duplicate() 				if visual.material_override != null else StandardMaterial3D.new()
			var material := visual.material_override as StandardMaterial3D
			if material != null:
				material.albedo_color = Color(
					float(albedo_values[0]), float(albedo_values[1]),
					float(albedo_values[2]),
					float(albedo_values[3]) if albedo_values.size() > 3 else 1.0)
	if bool(record.get("frozen", false)):
		prop.freeze = true
		PropFactory.set_frozen_look(prop, true)
	return prop


func count() -> int:
	return _undo_stack.size()


func describe() -> String:
	return "props=%d" % _undo_stack.size()
