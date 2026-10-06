extends Node
## Per-frame ankle trajectory probe for the reported "one frame is yanked
## backwards, left then right, every step" twitch.
##
## The existing window probes measure *aggregate* drift over a stance, which is
## exactly the number that stays small while a single-frame pop hides inside
## the average. This one records the ankle's world position **every frame** and
## reports the frame-to-frame deltas, so a one-frame discontinuity shows up as
## one large spike rather than being averaged into a number that looks fine.
##
## What it prints, per side:
##   * the planted flag's transitions, so a spike can be lined up against the
##     moment a pin was set or handed back;
##   * the largest single-frame deltas, with the frame index, the solve weight
##     and the pin-vs-actual distance at that frame — the three numbers that
##     together say *why* the foot moved that far.
##
## Read-only: it drives the game and observes, changing nothing.

const WALK_SECONDS: float = 4.0
## Seconds of start-up to discard: the boot settles, the body ramps to speed
## and the gait has not engaged yet.
const SETTLE_SECONDS: float = 1.2
## A per-frame delta above this (metres) is reported. The measured steady
## stride at the walk speed moves the ankle a few centimetres per frame; a pop
## is an order of magnitude past that. The threshold is deliberately low and
## the *count* is what matters — a stride that yanks will show a handful of
## large deltas, while a clean gait shows a long tail of small ones.
const SPIKE: float = 0.030
## Cap on how many spikes to print per side, so one pathological run cannot
## bury the report.
const MAX_REPORT: int = 8
## A spike counts as "per stride" if the same side spikes again within this
## many frames. The walk clip is 1.25 s played at ~2.3x, so a full stride cycle
## lands near 30 frames; one spike per stride separates cleanly from a
## per-frame instability and from a per-clip-wrap pop (which would be further
## apart than the cycle).
const STRIDE_WINDOW: int = 40

var _player: Player
var _ik: ModelFootIK
var _clips: ModelClips
var _skel: Skeleton3D
var _feet: Array[int] = [-1, -1]
var _prev_ankle: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _anchored: bool = false
var _elapsed: float = 0.0
var _frame: int = 0
var _reports: Array[int] = [0, 0]
var _worst: Array[float] = [0.0, 0.0]
var _worst_frame: Array[int] = [-1, -1]
var _prev_planted: Array[bool] = [false, false]
## Frame index at which each side last had a pin set (0) or handed back (1).
var _last_transition: Array[int] = [-99, -99]
var _last_transition_kind: Array[int] = [-1, -1]
## Every frame index at which this side spiked, so the *spacing* can be read —
## the spacing is what separates "once per stride" (a gait problem) from
## "once per clip wrap" (a loop problem) from "every frame" (a sampling
## problem), and those three have three different fixes.
var _spike_frames: Array[Array] = [[], []]
## The clip phase (seconds within the played clip) at each spike.
var _spike_phase: Array[Array] = [[], []]
var _phase_accum: float = 0.0
## The synthetic movement actions currently held down, so `_release_input`
## can drop exactly what was pressed and nothing else.
var _pressed: Array[StringName] = []
## Per-side clearance extremes over the measured window, and whether the
## clearance ever fell to the plant threshold at all.
var _clear_min: Array[float] = [INF, INF]
var _clear_max: Array[float] = [-INF, -INF]
var _clear_seen: Array[bool] = [false, false]
var _clear_below: Array[bool] = [false, false]


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var packed: PackedScene = load("res://src/boot/startup.tscn") as PackedScene
	add_child(packed.instantiate())
	Events.world_ready.connect(_on_world_ready)


func _on_world_ready(_world: Node3D) -> void:
	_player = get_tree().get_first_node_in_group(&"player") as Player
	if _player == null:
		print("[twitch-probe] FAIL: no player after boot")
		get_tree().quit(1)
		return
	var model := _player.get_node_or_null("PlayerModel") as Node3D
	if model == null:
		print("[twitch-probe] FAIL: no PlayerModel")
		get_tree().quit(1)
		return
	# The overlays are mounted on the *skeleton*, not on the model root —
	# `FigureAttachments._mount_modifier` adds them to the Skeleton3D so the
	# engine runs them as modifiers. Look there first, then fall back to the
	# root for the plain nodes (Clips, Stance are children of the model).
	for node: Node in model.find_children("*", "Skeleton3D", true, false):
		_skel = node as Skeleton3D
		_ik = _skel.get_node_or_null("FootIK") as ModelFootIK
		_clips = model.get_node_or_null("Clips") as ModelClips
		break
	if _skel == null:
		print("[twitch-probe] FAIL: no skeleton")
		get_tree().quit(1)
		return
	if _ik == null and _clips == null:
		print("[twitch-probe] FAIL: neither FootIK nor Clips found (skeleton=%s)" % str(_skel))
		get_tree().quit(1)
		return
	if _ik == null:
		print("[twitch-probe] FAIL: no FootIK modifier under the skeleton")
		get_tree().quit(1)
		return
	_feet[0] = _skel.find_bone(&"LeftFoot")
	_feet[1] = _skel.find_bone(&"RightFoot")
	if _feet[0] < 0 or _feet[1] < 0:
		print("[twitch-probe] FAIL: no VRM-named foot bones (LeftFoot/RightFoot)")
		get_tree().quit(1)
		return
	_hold_input()
	print("[twitch-probe] walking at the configured walk speed for %.1f s" % WALK_SECONDS)


## Hold the movement input for the whole run.
##
## Without it the player never leaves the origin: `ModelClips` decides what to
## play from *measured* speed, and a figure standing still measures zero, so it
## plays the standing stance. A first version of this probe did exactly that and
## reported a large "twitch" that was really just the idle sway — the gait was
## never running at all. The pin gap growing monotonically is the tell: a
## planted figure's gap is bounded by the leg's reach, an un-planted one grows
## without limit.
##
## The input is the real path: `Player._physics_process` reads
## `Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back")`,
## so pressing the action drives the body through the same code as a player
## would. Writing `velocity` directly would be overwritten on the next tick.
func _hold_input() -> void:
	if _pressed.is_empty():
		_pressed.append(&"move_forward")
		Input.action_press(&"move_forward")


func _release_input() -> void:
	for action: StringName in _pressed:
		Input.action_release(action)
	_pressed.clear()


## Sample after the component tick, so what is measured is the pose that gets
## rendered rather than the one the physics tick just dragged one body-step
## off the pin — the same discipline the window probes use.
func _process(delta: float) -> void:
	if _skel == null or _feet[0] < 0:
		return
	if not _anchored:
		_anchored = true
		_prev_ankle[0] = _ankle(0)
		_prev_ankle[1] = _ankle(1)
		return
	_frame += 1
	_elapsed += delta
	# Re-assert the hold every frame: `action_press` is an edge, and the
	# player's own input handling can clear it.
	_hold_input()
	# Skip the start-up stretch: the boot settles, the body is still ramping to
	# speed, and the gait has not engaged. Measuring it would report the
	# acceleration as a twitch.
	if _elapsed < SETTLE_SECONDS:
		_prev_ankle[0] = _ankle(0)
		_prev_ankle[1] = _ankle(1)
		return
	# Accumulate the clip phase the same way the component does, so a spike can
	# be located *within* the cycle rather than only in wall-clock frames.
	if _clips != null and _clips._current_clip != null:
		var rate := 1.0
		if _clips._running:
			rate = clampf(_clips._speed / _clips.run_authored_speed, 0.6, 2.4)
		elif _clips._walking:
			rate = clampf(_clips._speed / _clips.clip_authored_speed, 0.6, 2.4)
		_phase_accum += delta * rate
	for side: int in 2:
		var ankle := _ankle(side)
		var moved: float = (ankle - _prev_ankle[side]).length()
		var planted: bool = _ik._planted[side]
		# Line a spike up against the pin transition it landed on: a pop that
		# coincides with a pin being set is the pin snapping, one that
		# coincides with a release is the hand-back, and one with neither is
		# the solve itself losing the foot.
		if planted != _prev_planted[side]:
			_last_transition[side] = _frame
			_last_transition_kind[side] = 1 if planted else 0
		if moved > _worst[side]:
			_worst[side] = moved
			_worst_frame[side] = _frame
		# Always record the spike, even past the print cap: the *spacing* is
		# the diagnosis, and truncating the list would truncate the evidence.
		# Only the printing is capped.
		if moved > SPIKE:
			_spike_frames[side].append(_frame)
			_spike_phase[side].append(fposmod(_phase_accum, _clip_length()))
		# Track the clearance range per side: the plant test compares it
		# against `plant_enter`, so a figure whose *lowest* clearance over a
		# whole stride never reaches the threshold never plants, and the range
		# says so in one line. `_process_foot` sets `_clearance` to INF when
		# the ray misses, so this only ever reads real hits.
		if is_finite(_ik.last_clearance(side)):
			if not _clear_seen[side]:
				var first: float = _ik.last_clearance(side)
				_clear_min[side] = first
				_clear_max[side] = first
				_clear_seen[side] = true
			else:
				_clear_min[side] = minf(_clear_min[side], _ik.last_clearance(side))
				_clear_max[side] = maxf(_clear_max[side], _ik.last_clearance(side))
			_clear_below[side] = _clear_below[side] or _ik.last_clearance(side) <= _ik.plant_enter
		if moved > SPIKE and _reports[side] < MAX_REPORT:
			_reports[side] += 1
			var since: int = _frame - _last_transition[side]
			var kind := "none"
			if since <= 1 and _last_transition_kind[side] >= 0:
				kind = "pin-set" if _last_transition_kind[side] == 1 else "released"
			print(
				"[twitch-probe] %s frame %d: ankle moved %.4f m  (weight %.2f, planted %s, pin gap %.3f, %s%s)"
				% [
					_side_name(side), _frame, moved,
					_ik.foot_weight(side), str(planted), _pin_gap(side), kind,
					"" if since > 1 else " [same frame]",
				]
			)
		_prev_ankle[side] = ankle
		_prev_planted[side] = planted
	if _elapsed >= WALK_SECONDS:
		_report()


func _report() -> void:
	print("[twitch-probe] --- summary over %.0f frames (%.1f s) ---" % [_frame, _elapsed])
	print("[twitch-probe] clip length %.3f s" % _clip_length())
	for side: int in 2:
		print(
			"[twitch-probe] %s: largest single-frame ankle move %.4f m at frame %d; %d spikes over %.3f m"
			% [_side_name(side), _worst[side], _worst_frame[side], _reports[side], SPIKE]
		)
		var frames: Array = _spike_frames[side]
		if frames.size() >= 1:
			var gaps: Array[int] = []
			for i: int in range(1, frames.size()):
				gaps.append(int(frames[i]) - int(frames[i - 1]))
			print("[twitch-probe]   %s spike frames: %s" % [_side_name(side), str(frames)])
			print("[twitch-probe]   %s spike gaps (frames): %s" % [_side_name(side), str(gaps)])
			var phases: Array = _spike_phase[side]
			var rounded: Array[String] = []
			for p: float in phases:
				rounded.append("%.2f" % p)
			print("[twitch-probe]   %s clip phase at spike: %s" % [
				_side_name(side), str(rounded)
			])
			# A stride period is one full cycle; a clip wrap is also one cycle,
			# so the phase is what separates them: spikes clustered at a
			# constant phase are a pose problem in the clip, spikes spread
			# evenly through the phase are a sampling or solve problem.
			var spread := 0.0
			if phases.size() >= 2:
				spread = _phase_spread(phases)
			print("[twitch-probe]   %s clip-phase spread: %.3f s (0 = locked to one moment in the cycle)" % [
				_side_name(side), spread
			])
	if _clips != null:
		print("[twitch-probe] gear: walking=%s running=%s" % [str(_clips._walking), str(_clips._running)])
		print("[twitch-probe] measured speed %.2f m/s (smoothed %.2f)" % [
			_player.speed if _player != null else 0.0,
			_clips._speed,
		])
		if not _clips._walking:
			print("[twitch-probe] NOTE: the gait never engaged — these numbers are the idle sway, not a walk")
		# Why did the foot IK contribute nothing? Three candidates, and they
		# have different fixes: no camera in the viewport, the camera too far
		# (the cull), or the component simply not mounted where expected.
		print("[twitch-probe] foot IK: active=%s near_camera=%s" % [
			str(_ik.active), str(_ik._near_camera())
		])
		var cam := _skel.get_viewport().get_camera_3d() as Camera3D
		print("[twitch-probe] camera: %s" % (
			"none in viewport" if cam == null else "at %s, %.2f m from the figure" % [
				str(cam.global_position), cam.global_position.distance_to(_skel.global_position)
			]
		))
		# A planted figure cannot have its pin further away than the leg's
		# reach; an un-planted one grows without bound. This is the tell that
		# separates "the IK is solving" from "the IK never ran".
		for side: int in 2:
			print("[twitch-probe]   %s: weight %.2f planted %s pin gap %.3f m reach %.3f m" % [
				_side_name(side), _ik.foot_weight(side), str(_ik._planted[side]),
				_pin_gap(side), _reach(side)
			])
			# The clearance the plant test actually reads, against the two
			# thresholds it compares to. A clearance that never drops below
			# `plant_enter` means the foot is never close enough to the ground
			# to plant — which is a *pose* question (the clip holds the ankle
			# high) and not a detection question. `ground_found` separates the
			# two: false means the ray missed entirely.
			print("[twitch-probe]   %s: clearance %.4f m (ground_found %s, enter %.3f, exit %.3f)" % [
				_side_name(side), _ik.last_clearance(side), str(_ik.ground_found(side)),
				_ik.plant_enter, _ik.plant_exit
			])
			if _clear_seen[side]:
				print("[twitch-probe]   %s: clearance over the window %.4f..%.4f m; reached the plant threshold: %s" % [
					_side_name(side), _clear_min[side], _clear_max[side],
					"YES" if _clear_below[side] else "NO"
				])
	_release_input()
	# The report is diagnostic, not a pass/fail: the caller reads the numbers.
	get_tree().quit(0)


## Largest gap between consecutive phases, wrapping the circle — the tightest
## a set of phases can be clustered.
func _phase_spread(phases: Array) -> float:
	var length := _clip_length()
	if length <= 0.0 or phases.size() < 2:
		return 0.0
	var sorted_phases: Array[float] = []
	for p: float in phases:
		sorted_phases.append(p)
	sorted_phases.sort()
	var widest := 0.0
	for i: int in sorted_phases.size():
		var a: float = sorted_phases[i]
		var b: float = sorted_phases[i + 1] if i + 1 < sorted_phases.size() else sorted_phases[0] + length
		widest = maxf(widest, b - a)
	# The cluster's extent is the complement of its widest gap.
	return length - widest


func _clip_length() -> float:
	if _clips != null and _clips._current_clip != null:
		return _clips._current_clip.length
	if _clips != null:
		return 1.25
	return 1.0


func _side_name(side: int) -> String:
	return "left" if side == 0 else "right"


func _ankle(side: int) -> Vector3:
	return _skel.get_bone_global_pose(_feet[side]).origin


## How far the ankle currently sits from the pin it is being held to. Large
## while planted means the reach clamp is at work; large just after a release
## is the hand-back tail.
func _pin_gap(side: int) -> float:
	var pin: Vector3 = _ik._plant_pos[side]
	if pin == Vector3.ZERO:
		return 0.0
	return (pin - _ankle(side)).length()


## How far the hip can reach with this leg fully extended — the ceiling a
## planted foot's pin gap can never exceed.
func _reach(side: int) -> float:
	var chain: Dictionary = _ik._chains[side]
	var upper: int = int(chain.get("upper", -1))
	var lower: int = int(chain.get("lower", -1))
	var foot: int = int(chain.get("foot", -1))
	if upper < 0 or lower < 0 or foot < 0:
		return 0.0
	return _ik._rest_length(upper, lower) + _ik._rest_length(lower, foot)
