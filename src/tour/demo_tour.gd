extends Node
class_name DemoTour
## The guided tour: nine demonstration stops that walk a new player through
## every delivered module, and then get out of the way.
##
## Design (docs/demo_design.md): walking near a stop shows a hint card that
## teaches one module and asks the player to perform it once; performing it
## lights the stop and raises the progress counter. Completing all nine ends
## the tour and the map is an ordinary sandbox again.
##
## Universal by construction:
##   * **No progress gates.** Everything a stop teaches is available from the
##     first second; the tour only introduces it.
##   * **Two modes.** `TOUR` shows the stops; `SANDBOX` hides them entirely
##     (the hint card never appears, stops are still judged so a player who
##     changes their mind later finds their progress intact). The choice is
##     recorded like any other decision, so it survives saves and syncs.
##   * **Positions belong to the map.** This service owns what a stop *means*
##     and how it is judged; the map declares where its built-in stops stand
##     (`declare_builtin_stops`), and mods add stops through `ModContext`.
##
## Every completion is a decision (`tour_step`) so saves, replay and the
## multiplayer transport all carry the progress for free.

## Decision kinds.
const STEP_KIND: StringName = &"tour_step"
const MODE_KIND: StringName = &"tour_mode"
## How often the cheap poll runs (distance goals, constraint count, arrival).
const POLL_INTERVAL: float = 0.25
## Distance (m) the welcome stop asks for.
const WELCOME_DISTANCE: float = 20.0
## Distance (m) a vehicle must be driven to satisfy its stop.
const VEHICLE_DISTANCE: float = 30.0

enum Mode { UNSET, TOUR, SANDBOX }

## The built-in stops: id → card copy. Positions come from the map.
const BUILT_IN: Dictionary = {
	&"welcome": {
		"name": "欢迎台",
		"hint": "WASD 走，空格跳。滚轮缩放视角，T/G 升降镜头。",
		"requirement": "累计移动 20 米",
	},
	&"scenery": {
		"name": "池畔观景",
		"hint": "F4 切换时段，F2 切换画风——这张图的气氛随时可换。",
		"requirement": "F2 与 F4 各切换一次",
	},
	&"wardrobe": {
		"name": "衣帽间",
		"hint": "按 V 打开衣柜，拖动滑条或更换衣物。",
		"requirement": "在衣柜里修改一次外观",
	},
	&"citizens": {
		"name": "街角",
		"hint": "市民在执行自己的日程。走近一位按 E，可以编辑其外观。",
		"requirement": "编辑一位市民的外观",
	},
	&"props": {
		"name": "道具场",
		"hint": "Q 打开生成菜单放置一个箱子。鼠标左键抓取，右键冻结或解冻。",
		"requirement": "生成并冻结各一次",
	},
	&"workshop": {
		"name": "工坊",
		"hint": "按 3 拿起工具枪，滚轮选择焊接或绳索；先点一个道具，再点另一个。",
		"requirement": "创建至少一条约束",
	},
	&"vehicles": {
		"name": "车道",
		"hint": "走近车辆按交互键上车，开着它跑一段。",
		"requirement": "驾驶 30 米",
	},
	&"photo": {
		"name": "湖畔机位",
		"hint": "按 P 进入拍照模式，F10 保存当前画面。",
		"requirement": "保存一张照片",
	},
	&"exit": {
		"name": "出口平台",
		"hint": "九站全部点亮后，这张图就没有规则了。",
		"requirement": "走到这里",
	},
}

## Fired whenever a stop lights up or the mode changes, so the HUD can refresh
## without polling.
signal progress_changed(done: int, total: int)
signal stop_completed(stop_id: StringName)
signal mode_changed(new_mode: int)

var mode: Mode = Mode.UNSET
## stop_id → TourStop node.
var _stops: Dictionary = {}
## stop_id → true, for stops that have been demonstrated.
var _satisfied: Dictionary = {}
var _player: Node3D = null
var _poll_timer: float = 0.0
var _checkers: Dictionary = {}

# Judgement flags fed by events (see `_connect_sources`).
var _style_switched: bool = false
var _preset_switched: bool = false
var _appearance_edited: bool = false
var _npc_edited: bool = false
var _prop_spawned: bool = false
var _prop_frozen: bool = false
var _photo_saved: bool = false
# Vehicle progress: the node being driven and the odometer for this ride.
var _vehicle: Node3D = null
var _vehicle_last: Vector3 = Vector3.ZERO
var _vehicle_distance: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_checkers = _make_checkers()
	DecisionLog.register_applier(STEP_KIND, _apply_step)
	DecisionLog.register_applier(MODE_KIND, _apply_mode)
	_connect_sources()
	# The tour owns its own face (the same pattern as photo mode): a card, a
	# badge and the one-time start choice, on their own layer.
	var hud := TourHUD.new()
	hud.name = "TourHUD"
	hud.bind(self)
	add_child(hud)


## Whether a player exists yet — the start choice waits for one, and the poll
## needs one.
func has_player() -> bool:
	return _player != null


func _connect_sources() -> void:
	Events.player_spawned.connect(_on_player_spawned)
	Events.world_ready.connect(_on_world_ready)
	Events.render_style_changed.connect(_on_style_changed)
	Events.look_preset_changed.connect(_on_preset_changed)
	Events.prop_spawned.connect(_on_prop_spawned)
	Events.prop_frozen.connect(_on_prop_frozen)
	Events.vehicle_entered.connect(_on_vehicle_entered)
	Events.vehicle_exited.connect(_on_vehicle_exited)
	Events.appearance_edited.connect(_on_appearance_edited)
	Events.photo_saved.connect(_on_photo_saved)
	DecisionLog.decision_applied.connect(_on_decision_applied)


# --- Registration ---------------------------------------------------------

## Where the map's built-in stops stand. Everything else about them is the
## tour's own design; the map owns the ground plan (like the decor zones).
func declare_builtin_stops(positions: Dictionary) -> void:
	for stop_id: StringName in BUILT_IN:
		if _stops.has(stop_id):
			continue
		var data: Dictionary = BUILT_IN[stop_id]
		var at: Vector3 = positions.get(stop_id, Vector3.ZERO)
		register_stop(
			stop_id, String(data.name), String(data.hint),
			String(data.requirement), at,
			_checkers.get(stop_id, Callable()), float(data.get("radius", 4.5))
		)


## Add a stop. Mods reach this through `ModContext.add_tour_stop`; the map uses
## it (indirectly) for the built-in nine. Returns false when the id is taken.
func register_stop(
	stop_id: StringName,
	display_name: String,
	hint: String,
	requirement: String,
	at: Vector3,
	checker: Callable,
	radius: float = 4.5
) -> bool:
	if stop_id == &"" or _stops.has(stop_id):
		push_warning("[tour] stop id '%s' is empty or already taken" % stop_id)
		return false
	var stop := TourStop.new()
	stop.name = String(stop_id)
	stop.stop_id = stop_id
	stop.display_name = display_name
	stop.hint = hint
	stop.requirement = requirement
	stop.checker = checker
	stop.radius = radius
	add_child(stop)
	stop.global_position = at
	stop.setup()
	_stops[stop_id] = stop
	progress_changed.emit(_satisfied.size(), _stops.size())
	return true


# --- Mode -----------------------------------------------------------------

## Choose how this session treats the tour. Recorded as a decision so the
## answer survives a save and reaches the other end of a multiplayer session.
func set_mode(new_mode: Mode) -> void:
	if mode == new_mode:
		return
	mode = new_mode
	DecisionLog.record(MODE_KIND, {"mode": mode_to_string(new_mode)})
	mode_changed.emit(new_mode)


## Decide on first spawn. A save that already carries progress is a returning
## player: straight to the sandbox rhythm, no card. A fresh world *stays*
## UNSET — the HUD's start card asks, and the player's answer (Enter to follow
## the tour, Esc to build) is what records a mode.
func _resolve_initial_mode() -> void:
	if mode != Mode.UNSET:
		return
	if not _satisfied.is_empty():
		set_mode(Mode.SANDBOX)


static func mode_to_string(value: int) -> String:
	return "sandbox" if value == Mode.SANDBOX else "tour"


func is_completed(stop_id: StringName) -> bool:
	return _satisfied.has(stop_id)


func completed_count() -> int:
	return _satisfied.size()


func stop_count() -> int:
	return _stops.size()


func get_stop(stop_id: StringName) -> TourStop:
	return _stops.get(stop_id, null) as TourStop


## The stop the player is standing in, or null — what the hint card shows.
func active_stop() -> TourStop:
	if _player == null:
		return null
	for stop: TourStop in _stops.values():
		if stop.contains_player():
			return stop
	return null


# --- Judging --------------------------------------------------------------

func _process(delta: float) -> void:
	# UNSET means the start card is still open: nothing is judged until the
	# player has answered it.
	if _player == null or _stops.is_empty() or mode == Mode.UNSET:
		return
	_poll_timer -= delta
	if _poll_timer > 0.0:
		return
	_poll_timer = POLL_INTERVAL
	_track_vehicle_distance()
	for stop: TourStop in _stops.values():
		if _satisfied.has(stop.stop_id):
			continue
		if stop.is_satisfied():
			_mark(stop.stop_id)


## Each stop's demonstration check. Event-fed flags are combined here so the
## state machine is one table rather than nine special cases.
func _make_checkers() -> Dictionary:
	return {
		&"welcome": func() -> bool:
			return GameState.total_distance_travelled >= WELCOME_DISTANCE,
		&"scenery": func() -> bool:
			return _style_switched and _preset_switched,
		&"wardrobe": func() -> bool: return _appearance_edited,
		&"citizens": func() -> bool: return _npc_edited,
		&"props": func() -> bool: return _prop_spawned and _prop_frozen,
		&"workshop": func() -> bool:
			var store: ConstraintStore = Services.get_as(
				&"constraint_store", &"ConstraintStore") as ConstraintStore
			return store != null and store.count() > 0,
		&"vehicles": func() -> bool: return _vehicle_distance >= VEHICLE_DISTANCE,
		&"photo": func() -> bool: return _photo_saved,
		&"exit": func() -> bool:
			var stop: TourStop = _stops.get(&"exit", null) as TourStop
			return stop != null and stop.contains_player(),
	}


## Light a stop up. Local state first (the convention for decisions), then the
## journal record — saves, replay and the transport all carry it.
func _mark(stop_id: StringName) -> void:
	if _satisfied.has(stop_id):
		return
	_satisfied[stop_id] = true
	Events.notify(
		"已演示：%s（%d/%d）" % [
			String(BUILT_IN.get(stop_id, {}).get("name", stop_id)),
			_satisfied.size(), _stops.size(),
		],
		Events.NotifyLevel.INFO
	)
	DecisionLog.record(STEP_KIND, {"step": String(stop_id)})
	stop_completed.emit(stop_id)
	progress_changed.emit(_satisfied.size(), _stops.size())
	if _satisfied.size() >= _stops.size():
		Events.notify("全部模块已演示——接下来没有规则，自由建造。", Events.NotifyLevel.INFO)


# --- Replay appliers (also the remote-decision entry) ---------------------

func _apply_step(payload: Dictionary) -> void:
	var stop_id := StringName(String(payload.get("step", "")))
	if stop_id == &"":
		return
	_satisfied[stop_id] = true
	progress_changed.emit(_satisfied.size(), _stops.size())


func _apply_mode(payload: Dictionary) -> void:
	mode = Mode.SANDBOX if String(payload.get("mode", "tour")) == "sandbox" else Mode.TOUR
	mode_changed.emit(mode)


# --- Event sources --------------------------------------------------------

func _on_player_spawned(player: Node3D) -> void:
	_player = player
	_resolve_initial_mode()


## Mod stops are materialised once the world exists — the map has declared its
## built-ins by then, so a mod stop and a built-in are indistinguishable in the
## progress list.
func _on_world_ready(_world: Node3D) -> void:
	apply_mod_stops()


## Turn what mods registered through `ModContext.add_tour_stop` into real stops.
## Public so a probe can drive it without a world.
func apply_mod_stops() -> void:
	for entry: Dictionary in ModHost.content_ordered(&"tour"):
		register_stop(
			StringName(String(entry.get("id", ""))),
			String(entry.get("display_name", "")),
			String(entry.get("hint", "")),
			String(entry.get("requirement", "")),
			entry.get("position", Vector3.ZERO) as Vector3,
			entry.get("checker", Callable()) as Callable,
			float(entry.get("radius", 4.5))
		)


func _on_style_changed(_id: StringName, _name: String) -> void:
	_style_switched = true


func _on_preset_changed(_id: StringName, _name: String) -> void:
	_preset_switched = true


func _on_prop_spawned(_prop: Node, _prop_id: StringName) -> void:
	_prop_spawned = true


func _on_prop_frozen(_prop: Node, _frozen: bool) -> void:
	_prop_frozen = true


func _on_appearance_edited() -> void:
	_appearance_edited = true


func _on_photo_saved(_path: String) -> void:
	_photo_saved = true


func _on_vehicle_entered(vehicle: Node3D, _driver: Node3D) -> void:
	_vehicle = vehicle
	_vehicle_last = vehicle.global_position
	_vehicle_distance = 0.0


func _on_vehicle_exited(_vehicle_node: Node3D, _driver: Node3D) -> void:
	_vehicle = null


## NPC appearance edits arrive as decisions (they are what the save replays),
## so the tour listens on the same channel instead of the panel's UI.
func _on_decision_applied(kind: StringName, _payload: Dictionary) -> void:
	if kind == &"set_npc_figure":
		_npc_edited = true


## Odometer for the ride in progress. Polled rather than event-driven because
## a vehicle has no "moved" event and inventing one would wire the transport
## layer into a tutorial.
func _track_vehicle_distance() -> void:
	if _vehicle == null or not is_instance_valid(_vehicle):
		return
	var now: Vector3 = _vehicle.global_position
	var step: float = (now - _vehicle_last).length()
	_vehicle_last = now
	if step < 5.0:
		_vehicle_distance += step
