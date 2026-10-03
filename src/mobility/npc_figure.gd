extends Node
class_name NpcFigure
## On-demand rendering for citizens that share the base figure.
##
## The player's body is one `base_female.vrm`; every citizen instantiates the
## same PackedScene and differs only in a seeded parameter set (shape-key
## weights + garment visibility — all per-instance state, measured not to leak
## into the shared mesh resources). With N citizens that makes the per-instance
## costs — draw calls, skinning, the stance's bone writes — the whole story,
## so this configurator pushes each of them behind a "needed?" gate:
##
## * **Distance cull, renderer-side**: every mesh gets `visibility_range_end`,
##   so a citizen beyond the range costs nothing at all — no script runs, the
##   render server simply drops the instances. A street full of distant people
##   is free; the ones near the camera pay.
## * **Shadow discipline**: only the body and head cast shadows. Garment
##   shadows are invisible at citizen distances, and dropping them turns 15
##   shadow-pass draw calls per citizen into 2.
##
## The stance's per-frame bone writes have their own distance gate inside
## `ModelStance` (`active_range`) — the two thresholds are deliberately
## different: a citizen between 45 m and 55 m is still rendered (frozen
## mid-sway, which no one can see at that distance) but stops animating.

## Beyond this many metres a citizen's meshes are culled by the renderer.
const VISIBILITY_RANGE: float = 55.0
## The meshes whose shadows survive the discipline: one skinned draw call per
## citizen in the shadow pass instead of fifteen.
const SHADOW_CASTERS: PackedStringArray = ["SiroinoSotai_Body", "Akane_Head"]
## The decision kind this module owns: an appearance override for one citizen,
## keyed by that citizen's figure seed. Emitted through `DecisionLog`, so the
## override is journaled (crash-safe) and broadcast (multiplayer) without this
## file knowing either transport or storage.
const DECISION_KIND: StringName = &"set_npc_figure"

## figure seed -> the parameter dictionary overriding that citizen's seeded
## look. Fed by the decision applier (live edits and journal replay alike) and
## read by `PedestrianAgent.apply_base_figure` at spawn time — so an override
## made last session re-applies to a citizen that has been regenerated since.
static var _overrides: Dictionary = {}
static var _applier_registered: bool = false


## Apply the on-demand configuration to a freshly instantiated figure.
static func configure(model: Node3D) -> void:
	if model == null:
		return
	register_decision_applier()
	for node: Node in model.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		mesh_instance.visibility_range_end = VISIBILITY_RANGE
		if mesh_instance.name in SHADOW_CASTERS:
			mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		else:
			mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## Re-edit one citizen's look: emit the decision — journaling and (later)
## multiplayer broadcast are the log's job, not the caller's.
static func emit_figure_override(seed_key: int, values: Dictionary) -> void:
	register_decision_applier()
	DecisionLog.emit(DECISION_KIND, {"seed": seed_key, "values": values})


## The stored override for a seed, if any citizen ever had their look edited.
static func get_override(seed_key: int) -> Dictionary:
	return _overrides.get(seed_key, {})


## Register this module's decision applier once. The applier is deliberately
## store-first: replay may run before any citizen exists (the crowd is
## regenerated from seed after load), so the override lands in the static map
## and every citizen — existing or future — applies it at spawn; live citizens
## get it pushed immediately as well.
static func register_decision_applier() -> void:
	if _applier_registered:
		return
	_applier_registered = true
	DecisionLog.register_applier(DECISION_KIND, func(payload: Dictionary) -> void:
		var seed_key := int(payload.get("seed", 0))
		var values: Dictionary = payload.get("values", {})
		_overrides[seed_key] = values
		_push_live(seed_key, values)
	)


static func _push_live(seed_key: int, values: Dictionary) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for node: Node in tree.get_nodes_in_group(&"citizens"):
		var agent := node as PedestrianAgent
		if agent != null and agent.figure_seed == seed_key:
			var parameters := ModelBlendShapes.find_on(agent.get_node_or_null("Figure"))
			if parameters != null:
				parameters.apply_values(values)
