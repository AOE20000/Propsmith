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
##
## ## The gate that is deliberately *not* here: don't build what nobody is near
##
## The obvious fourth gate is to skip instantiating a figure until its citizen
## comes close. It was built, measured, and dropped, and the numbers are worth
## keeping so nobody rebuilds it:
##
## * Building a figure costs **4 ms** once the scene is loaded (profiled:
##   `DSH_PROFILE_FIGURE=1`). The city's 40 citizens therefore cost ~0.9 s, and
##   that is paid during the map build — behind the loading screen, where a
##   one-time cost is invisible.
## * Deferring those builds into play would convert that hidden 0.9 s into ~40
##   stalls of a few milliseconds each, right at the start, in view. Worse, not
##   better.
## * The renderer already skips the *rendering* of far citizens for free: 40
##   dressed figures cost **22 draw calls** in total, because only the three or so
##   within the visibility range are drawn at all.
##
## What was actually wrong was the opposite of deferred work: `load()` was costing
## 380–400 ms *per citizen* because the reference died with `dress_agent` and the
## scene was re-parsed every time. See `_figure_scene`. The crowd was never
## expensive per head; it was expensive per *call*.

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

## Environment variable that forces the capsule fallback: `DSH_CITIZEN_APPEARANCE=capsule`.
##
## Exists for calibration. With a full crowd of figures the frame is dominated by
## them, and being able to bisect "is this the citizens?" without editing a line
## is worth one environment read.
const APPEARANCE_ENV: String = "DSH_CITIZEN_APPEARANCE"

## figure seed -> the parameter dictionary overriding that citizen's seeded
## look. Fed by the decision applier (live edits and journal replay alike) and
## read by `PedestrianAgent.apply_base_figure` at spawn time — so an override
## made last session re-applies to a citizen that has been regenerated since.
static var _overrides: Dictionary = {}
static var _applier_registered: bool = false
static var _save_registered: bool = false

## How many figures have been dressed this session, and how long it took in
## total. Dressing is the one crowd cost that is a *hitch* rather than a
## per-frame tax: it happens at load, it scales with the crowd, and nothing else
## in the world build scales the same way.
static var _dressed: int = 0
static var _dress_ms: int = 0
## The one-time scene load, which is inside `_dress_ms` and reported apart from it.
static var _scene_ms: int = 0
static var _default_appearance: StringName = &""
## Tri-state: -1 not yet resolved, 0 off, 1 on.
static var _profile_enabled: int = -1

## The shared figure scene, held for the whole session.
##
## Measured, and not what anyone would guess: `load()` on this path costs ~380 ms
## *every* call, not just the first. The local reference used to die with
## `dress_agent`, so the resource was evicted between citizens and re-parsed each
## time — eight citizens spent 3.4 s in the loader repeating work that only needed
## doing once, and the crowd's cost looked like an unavoidable per-citizen tax.
## Holding one reference turns the second and every later figure into a few
## milliseconds. `instantiate` was never the expensive part (2 ms); the profile is
## what said so.
static var _figure_scene: PackedScene = null


## What a citizen wears when the caller does not say: the shared base figure,
## unless the calibration environment variable asks for the capsule fallback.
##
## Cached because it is asked once per spawn and the answer cannot change inside a
## session — and because a per-spawn `OS.get_environment` would show up in exactly
## the measurement this exists to make possible.
static func default_appearance() -> StringName:
	if _default_appearance != &"":
		return _default_appearance
	var requested: String = OS.get_environment(APPEARANCE_ENV).strip_edges().to_lower()
	_default_appearance = &"capsule" if requested == "capsule" else &"vrm"
	return _default_appearance


## One line for the boot report.
##
## The one-time scene load and the per-figure cost are reported *separately*, and
## that separation is the whole point: the mean of the two is a number that
## describes nothing. The first version of this line printed
## `8 人 / 3451 ms（均 431 ms）` — which reads as an unavoidable 431 ms per citizen,
## and the truth was 760 ms once and 4 ms thereafter. The average hid precisely the
## part that could be fixed, and a fix was attempted against it.
static func cost_report() -> String:
	if _dressed == 0:
		return "0 人（胶囊）"
	if _dressed == 1:
		return "1 人 · 载入 %d ms · 随后均 —" % _scene_ms
	return "%d 人 · 载入 %d ms · 随后均 %.1f ms" % [
		_dressed, _scene_ms, float(_dress_ms - _scene_ms) / float(_dressed - 1),
	]


## Reset the counters. Only for tests, which dress figures repeatedly and would
## otherwise report the sum of every run so far.
static func reset_cost_counters() -> void:
	_dressed = 0
	_dress_ms = 0
	_scene_ms = 0


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
	DecisionLog.record(DECISION_KIND, {"seed": seed_key, "values": values})


## The stored override for a seed, if any citizen ever had their look edited.
static func get_override(seed_key: int) -> Dictionary:
	return _overrides.get(seed_key, {})


## Dress a citizen with the shared base figure: instantiate, attach the
## standard component stack, draw the seeded look, honour any journaled
## override, configure on-demand rendering, and add the edit handle. This is
## the whole appearance half of a citizen — `PedestrianAgent.apply_base_figure`
## is a one-line shell around it. Returns false when the figure asset is
## unavailable (the agent keeps its capsule and nothing else changes).
static func dress_agent(agent) -> bool:
	var started: int = Time.get_ticks_msec()
	var scene_path: String = agent.BASE_FIGURE_SCENE
	var packed: PackedScene = _resolve_scene(scene_path)
	if packed == null:
		return false
	var after_load: int = Time.get_ticks_msec()
	var model := packed.instantiate() as Node3D
	if model == null:
		return false
	var after_instance: int = Time.get_ticks_msec()
	model.name = "Figure"
	# The figure faces +Z; the citizen walks toward its -Z target, so turn the
	# model to match the movement code's facing assumption.
	model.rotation_degrees.y = 180.0
	agent.add_child(model)
	agent.figure = model
	FigureAttachments.attach_all(model)
	var after_stack: int = Time.get_ticks_msec()
	var parameters := ModelBlendShapes.find_on(model)
	if parameters != null:
		var rng := RandomNumberGenerator.new()
		rng.seed = hash("figure|%d" % agent.figure_seed)
		parameters.apply_values(ModelBlendShapes.randomized_values(rng))
		# A saved decision beats the seeded roll: if this citizen's look was
		# edited (and journaled) in any earlier session, that override wins.
		var override := get_override(agent.figure_seed)
		if not override.is_empty():
			parameters.apply_values(override)
	var after_look: int = Time.get_ticks_msec()
	configure(model)
	var after_gates: int = Time.get_ticks_msec()
	var editor := NpcFigureEditor.new()
	editor.agent = agent
	editor.position = Vector3(0.0, 1.2, 0.0)
	agent.add_child(editor)
	agent.figure_editor = editor
	var visual := agent.get_node_or_null("Visual") as MeshInstance3D
	if visual != null:
		visual.visible = false
	var finished: int = Time.get_ticks_msec()
	_dressed += 1
	_dress_ms += finished - started
	if _profiling():
		print("[figure] total %d ms = load %d + instantiate %d + stack %d + look %d + gates %d + handle %d" % [
			finished - started,
			after_load - started,
			after_instance - after_load,
			after_stack - after_instance,
			after_look - after_stack,
			after_gates - after_look,
			finished - after_gates,
		])
	return true


## Whether to print the per-figure timing breakdown (`DSH_PROFILE_FIGURE=1`).
## Dressing a figure is the most expensive thing the crowd does, and "where did
## the millisecond go" is not answerable from outside: the cost is spread across
## scene instantiation, component attachment and the per-instance upload that
## setting a shape-key weight triggers. Resolved once — this runs per figure and
## an environment read per figure would show up in its own measurement.
static func _profiling() -> bool:
	if _profile_enabled < 0:
		_profile_enabled = 1 if OS.get_environment("DSH_PROFILE_FIGURE") == "1" else 0
	return _profile_enabled == 1


## The shared figure scene, loaded at most once per session. See the note on
## `_figure_scene` for why this is not just `load(scene_path)` inline.
static func _resolve_scene(scene_path: String) -> PackedScene:
	if _figure_scene != null:
		return _figure_scene
	if not ResourceLoader.exists(scene_path, "PackedScene"):
		return null
	var started: int = Time.get_ticks_msec()
	_figure_scene = load(scene_path) as PackedScene
	_scene_ms = Time.get_ticks_msec() - started
	return _figure_scene


## Register this module's decision applier once. The applier is deliberately
## store-first: replay may run before any citizen exists (the crowd is
## regenerated from seed after load), so the override lands in the static map
## and every citizen — existing or future — applies it at spawn; live citizens
## get it pushed immediately as well.
## Idempotent one-stop registration: the decision applier + the save section.
static func ensure_registered() -> void:
	register_decision_applier()


static func register_decision_applier() -> void:
	if _applier_registered:
		return
	_applier_registered = true
	DecisionLog.register_applier(DECISION_KIND, func(payload: Dictionary) -> void:
		var seed_key := int(payload.get("seed", 0))
		var values: Dictionary = payload.get("values", {})
		_overrides[seed_key] = values
		_push_live(seed_key, values)
	, true)
	_register_save_section()


## The override table rides the save snapshot under its own section (all
## current decision kinds are snapshot-covered, so compaction may empty the
## journal after every save). Registered on first figure — idempotent.
static func _register_save_section() -> void:
	if _save_registered:
		return
	_save_registered = true
	SaveSystem.register_persistent(&"npc_figures",
		NpcFigure.serialize_overrides, NpcFigure.restore_overrides)


static func serialize_overrides() -> Dictionary:
	var encoded: Dictionary = {}
	for seed_key: int in _overrides:
		encoded[str(seed_key)] = _overrides[seed_key]
	return {"overrides": encoded}


static func restore_overrides(data: Dictionary) -> void:
	var overrides: Variant = data.get("overrides", {})
	if not (overrides is Dictionary):
		return
	for key: String in (overrides as Dictionary):
		var values: Variant = (overrides as Dictionary)[key]
		if values is Dictionary:
			_overrides[int(key)] = values
			_push_live(int(key), values)


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
