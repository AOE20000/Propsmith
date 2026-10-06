extends SkeletonModifier3D
class_name ModelFootIK
## Plants the feet instead of letting the clip slide them.
##
## **WIRED UP** — attached by `FigureAttachments.attach_all` right after the
## locomotion clips, so it reads the leg pose the clip just wrote and has the
## last word on the legs (head aim, lean and spring bones sit after it but
## touch only the spine up). Every piece below was earned by a probe; the
## numbers are the acceptance record.
##
## * The bend direction (`KNEE_SIGN`): the first build rotated about the
##   character's right axis and the picture showed a backwards knee. The
##   frame probe (`tools/foot_ik_frame_probe.gd`) now asserts a forward knee
##   on every scenario, identity and yawed rigs alike.
## * The two-bone solve: the thigh is aimed at the hip→goal **ray tilted off
##   by the law-of-cosines interior angle** (`_solve`), which makes
##   |goal − knee| equal the shin length by construction — the ankle lands
##   exactly at any bend, including the fold. The previous shape (thigh
##   swung straight at the goal) landed `|l2 − |d − l1||` short every solve —
##   ~7.4 cm at a running stance, the whole gap in a fold — and that
##   per-solve error, re-pinned every stride, was the 0.15-0.18 m/frame
##   full-weight drift. Frame probe: all scenarios err ≈ 1e-7; with the
##   conjugation forced off, the yawed rig errs 0.575 m (×5750 contrast).
## * The axis conjugation (`rig_rotation_fix`): the swing is computed in
##   world space but applied to a skeleton-local basis chain —
##   `R_local = R_node⁻¹ · R_world · R_node`. On an identity-oriented figure
##   both agree, which is why it took a yawed probe rig to see.
## * The pelvis compensation (`_pelvis_prepare`): the clips write the hips
##   **absolutely**, so our last drop is not in the pose we read — the old
##   undo-then-apply pair netted zero every locomotion frame and the
##   compensation never landed (a permanent ~0.19 m clamp shortfall, the
##   window probe spent weeks attributing it to the solve). The write-
##   detection pair (`_hips_base`/`_hips_written`) claims the bone only when
##   nobody re-posed it.
## * The reach release (`reach_exit`): a pin the leg plus the pelvis drop
##   cannot serve turns the plant into a drag anchor — the ankle scrapes
##   along behind the body. The release keys on the **pre-drop** shortfall
##   (the drop eases in over ~0.1 s; keying on the post-drop `over` waits
##   out the easing while the clamp drags — measured pins stuck at 0.15
##   against a 0.16 threshold) and hands the foot back; one real lift
##   re-arms planting.
## * The standstill handback (`still_speed`): every release above "hands the
##   foot back to the clip" — but when the figure has *stopped*, the clip has
##   stopped writing, and a faded correction just leaves the last written
##   pose in place: the figure froze mid-stride (the pins also re-pinned
##   themselves the frame after a plant-time release, the foot never having
##   moved). Below `still_speed` the pins are released and each owned chain
##   is eased back to its rest pose (`_process_standstill`) — surfacing only
##   once the gear threshold put the walk speed on the run clip, whose
##   pace-exact pins stick where the walk clip's stale pins used to churn.
##   The gate itself needed two layers of robustness the first cut lacked:
##   the speed reads the *interpolated* transform and is smoothed, and the
##   decision latches with hysteresis (`still_resume_speed`) — the raw
##   per-frame sample of a gliding body alternates hit/miss with the physics
##   ticks, and an un-latched gate flapped release/restore/re-plant all
##   through the decay tail ("it twitches twice before settling").
##
## **Measured acceptance** (window probe `tools/foot_ik_probe.gd`, sampling
## after the component tick — before that the probe read the pose the
## physics tick had just dragged one body-step off the pin, a 0.14 m
## sawtooth the rendered frame never shows):
##
##   * sprint (run gear, 8.6 m/s): held-pin drift 0.010 m/frame mean —
##     12% of body speed, was 78-80%; solve landing error 0.019 m in reach.
##   * walk (5.2 m/s at the time): held-pin drift 0.013 m/frame — 26% of
##     body speed, with a persistent ~0.10 m clamp gap. Root cause was the
##     gear choice, not the IK: the walk clip was authored at 1.3 m/s and its
##     playback cap (2.4×) tops out at 3.12 m/s of cadence, so at 5.2 m/s the
##     clip slid by design and pins went stale within ~0.1 s. Fixed
##     2026-10-05 (`ModelClips.run_threshold` 6.5 → 3.0, walk speed on the
##     run clip) and superseded 2026-10-06: the walk speed itself came down
##     to 3.0 m/s, so the walk clip plays honest (rate 2.31 — no clip slide,
##     small strides) and the walk bucket should read as near-zero drift.
##     The sprint keeps its small 5% cap.
##
## Also worth knowing on this rig:
##   * Bone length is the distance between adjacent bone origins. The rest
##     transform's Y axis is **not** it — Godot stores rest rotations without
##     scale, so `get_bone_global_rest(x).basis.y.length()` reads 1.0 for
##     every bone.
##   * The legs are short for the clip's hip heights (rest 0.873 vs a 0.724
##     chain): the pelvis drop is load-bearing every stride, not a fallback.
##
## Kept and still useful: the measurement harness (planted drift, solve error,
## chain lengths, ground clearance — all per side), the hysteresis phase test,
## and the visual probe that made the bend direction visible.

## The VRM 1.0 humanoid names, which the importer normalises to (the same
## convention `ModelStance` uses for the arms).
const UPPER: StringName = &"UpperLeg"
const LOWER: StringName = &"LowerLeg"
const FOOT: StringName = &"Foot"
const SIDES: Array[String] = ["Left", "Right"]
## How high the ankle sits above the sole. The plant test measures the ankle, so
## without this a foot resting flat on the ground reads as *hovering* by its own
## ankle height and never gets planted.
const ANKLE_HEIGHT: float = 0.085
## The pelvis bone — the one bone this component is allowed to move for its own
## reasons (see `_pelvis_prepare`).
const HIPS_BONE: StringName = &"Hips"
## Which way the thigh tilts off the hip→goal ray when the knee folds. Rotating
## the ray by **+**alpha about the bend normal (`-basis.x`) throws the knee to
## +Z — the model's *rear* (the figure faces -Z; the flip is authored in
## `player_scene`, see `Player._update_facing`) — and a knee belongs on the
## front side, so the tilt is negated. The frame probe asserts this on every
## scenario: the knee must sit on the model's forward side, identity and yawed
## rigs alike.
const KNEE_SIGN: float = -1.0

## How far below the foot a ground ray reaches, and how far above its start it
## begins (the foot is often slightly inside the ground on a slope).
@export var ray_up: float = 0.25
@export var ray_down: float = 0.55
## Clearance at which a foot counts as having landed, and the larger clearance
## at which it is released again. The gap between them is hysteresis, and it is
## not a nicety: with a single threshold the plant flag chatters whenever a foot
## skims the value, and every re-plant re-pins the foot where it currently is —
## which is no pin at all. Measured clearances while sprinting run 0.06–0.13 m
## in stance and 0.2–0.4 m in swing, so the thresholds sit in those gaps.
## Measured stance-phase clearance runs 0.06-0.13 m on this rig, so an enter
## threshold of 0.11 sat *inside* that band: the flag chattered, the weight
## never finished fading in, and the correction never reached full strength.
## The band has to sit above the stance measurements, not inside them.
@export var plant_enter: float = 0.17
@export var plant_exit: float = 0.28
## After this long standing still the foot is handed back to the clip, so a
## character that stops does not keep correcting a pose the animation owns.
@export var plant_max_time: float = 0.45
## Below this planar speed (m/s) the figure starts counting as standing still.
## It sits above the clip's own walk threshold (0.25) so the release lands
## while the stop blend still owns the pose.
@export var still_speed: float = 0.3
## Planar speed (m/s) above which a latched standstill unlatches. The gap to
## `still_speed` is hysteresis, and it is not a nicety: the raw per-frame
## speed of a decelerating body alternates (physics ticks land on render
## frames unevenly), and an un-latched gate around one threshold flapped —
## each flap released and restored the legs, then re-planted and re-dropped
## the pelvis. The playtest read that as "it twitches twice before settling".
@export var still_resume_speed: float = 0.6
## How fast the smoothed planar speed follows the measured one (per second).
## The smoothing is what turns the alternating hit/miss samples of a gliding
## body into one monotonic decay the hysteresis can work with.
@export var still_speed_lerp: float = 8.0
## Seconds of stillness before the standstill release fires. Short — the
## latch plus the smoothed speed already ride out one-frame dips, and the
## release wants to land near the stop blend's own window, not a third of a
## second after it.
@export var still_delay: float = 0.08
## Seconds the standstill restore takes per leg, from wherever the solve left
## it back to the rest pose — the same snapshot-plus-smoothstep the stop
## blend uses, because the failure it fixes is the same family: a pose left
## in place with nobody writing it.
@export var still_restore_time: float = 0.18
## How fast the correction fades in (per second). This has to be *faster* than
## a stride, not slower: a stance phase on this rig lasts about 0.1 s, so at
## 3/s the weight never left 0.25 and the foot was corrected by a quarter of
## what it needed. 9/s reaches full strength inside a stance; a hard switch
## would pop, this is as close to "immediate" as smooth can get.
@export var blend_speed: float = 9.0
## Seconds the release hand-off takes to ease a corrected leg into the
## clip's own pose. Short enough to read as "the animation takes the foot
## back", long enough that the handback is not a one-frame pop.
@export var release_blend: float = 0.12
## Skeletons farther than this from the camera stop per-frame IK, like the
## stance's distance gate.
@export var active_range: float = 45.0
## Ceiling on the pelvis drop (m). The real shortfall here is ~0.2 m — this
## figure's legs are shorter than its hips are high — but applying all of it
## moves the *whole body*: reported in play as the character lurching toward
## the frame edge and back. Take a fraction, let the reach clamp absorb the
## rest as a slightly straighter knee.
@export var max_pelvis_drop: float = 0.12
## How far beyond what the pelvis drop can absorb a pin may sit before the
## plant gives the foot back (m). The reach clamp answers an unreachable pin
## with a straight leg that scrapes along behind the body — at sprint speed
## the probe caught pins going metres stale before `plant_max_time` noticed.
## Released feet re-arm over one swing: the foot lifts, then may pin again.
@export var reach_exit: float = 0.04
## How fast the pelvis offset eases toward its goal (per second). The shortfall
## this reacts to rises and falls with every stride; without easing, the hips
## twitch in sympathy — reported in play as the legs snapping forward and
## jerking about three seconds into a run.
@export var pelvis_smoothing: float = 7.0
## The bend axis is measured in world space (bone origins and the pin are
## world), but the quaternion multiplies into a **skeleton-local** basis
## chain — `parent_global` is the node-relative frame, which is exactly the
## frame-of-reference trap the spring-bone probe documented (a +1 m node move
## leaves `get_bone_global_pose` untouched). A conjugated axis fixes it:
## `R_local = R_node⁻¹ · R_world · R_node` keeps the angle and carries the
## axis across. On an identity-oriented figure both agree, which is why the
## straight-line window probe never saw it; a yawed rig applies the swing in
## the wrong direction entirely.
@export var rig_rotation_fix: bool = true

var _skeleton: Skeleton3D = null
var _model: Node3D = null
## Per side: the three bone indices, or an empty dictionary when the rig has no
## legs of that side.
var _chains: Array[Dictionary] = [{}, {}]
## Per side: planted flag, the world point the foot is pinned to, how long it has
## been planted, and the current correction weight.
var _planted: Array[bool] = [false, false]
var _plant_pos: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _plant_time: Array[float] = [0.0, 0.0]
var _weight: Array[float] = [0.0, 0.0]
## Last measured foot height over the ground, per side (probe diagnostics).
var _clearance: Array[float] = [0.0, 0.0]
## Whether the ground ray found anything at all, per side.
var _grounded: Array[bool] = [false, false]
## How far the foot ended up from where the solve asked for (probe diagnostics).
var _ik_error: Array[float] = [0.0, 0.0]
## (thigh length, shin length, hip→target distance) from the last solve.
var _last_reach: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
## The pelvis offset currently in effect (world vector, eased by
## `pelvis_smoothing`).
var _pelvis_current: Vector3 = Vector3.ZERO
## The hips' pose origin as this frame found it, and as this component left it
## after the drop. The pair detects who owns the bone: the clips write an
## **absolute** Hips position, which retires our offset, so undoing "just in
## case" subtracts a drop the pose no longer contains — and the compensation
## never lands (that exact cancellation was the permanent clamp shortfall the
## window probe spent weeks attributing to the solve).
var _hips_base: Vector3 = Vector3.ZERO
var _hips_written: Vector3 = Vector3.ZERO
## (thigh angle, shin angle) the last solve asked for, and the goal it aimed at.
var _last_angles: Array[Vector2] = [Vector2.ZERO, Vector2.ZERO]
var _last_goal: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
## bone name -> the global basis this component last wrote, for the chain solve.
var _applied_global: Dictionary = {}
## Per side: a reach release happened and planting is held off until the foot
## has lifted through a real swing (see `reach_exit`). Re-pinning a dragging
## foot would just move the anchor under it — the slide this component
## exists to remove.
var _reach_released: Array[bool] = [false, false]
## Standstill bookkeeping: the model position the planar-speed sample reads
## against, whether that sample is real yet, how long the figure has been
## still, and the per-side restore blend (a snapshot of the pose this
## component last wrote, easing back to rest).
var _last_model_pos: Vector3 = Vector3.ZERO
var _pos_anchored: bool = false
var _still_time: float = 0.0
## The smoothed planar speed the stillness decision reads, and the latched
## decision itself (true between the enter and resume thresholds — the
## hysteresis that keeps the decay tail from flapping the release).
var _planar_speed: float = 0.0
var _still: bool = false
var _restore_from: Array[Dictionary] = [{}, {}]
var _restore_t: Array[float] = [0.0, 0.0]
## Per side: the leg poses captured at a release and the hand-off blend's
## clock. The correction eases into the clip's own pose — never back toward
## the pin, which the advancing body has already left behind.
var _release_from: Array[Dictionary] = [{}, {}]
var _release_t: Array[float] = [0.0, 0.0]
## Per side: the leg poses the restore wrote on its previous frame. The stop
## blend may start writing the legs while a restore is still running (the
## clip's smoothed speed crosses the walk threshold later than the standstill
## gate) — without this record the restore would keep easing from its own
## stale snapshot and yank the recovering legs backwards for a frame. If the
## recorded poses no longer match what is on the bones, someone else owns the
## legs and the restore stands down — the same ownership check the hips use.
var _restore_last: Array[Dictionary] = [{}, {}]


## Bind to a model root. A model without VRM-named leg bones (a capsule, a mod
## model) simply never plants.
func setup(model: Node3D) -> void:
	_model = model
	if model == null:
		return
	for candidate: Node in model.find_children("*", "Skeleton3D", true, false):
		_skeleton = candidate as Skeleton3D
		break
	if _skeleton == null:
		return
	for i: int in SIDES.size():
		_chains[i] = {
			"upper": _skeleton.find_bone(StringName("%s%s" % [SIDES[i], UPPER])),
			"lower": _skeleton.find_bone(StringName("%s%s" % [SIDES[i], LOWER])),
			"foot": _skeleton.find_bone(StringName("%s%s" % [SIDES[i], FOOT])),
		}
	# Re-setup starts the standstill measurement over (the model may have been
	# moved or rebuilt), and any restore in progress belongs to the old rig.
	_pos_anchored = false
	_still_time = 0.0
	_planar_speed = 0.0
	_still = false
	_release_from[0] = {}
	_release_from[1] = {}
	_release_t[0] = 0.0
	_release_t[1] = 0.0
	_cancel_restore(0)
	_cancel_restore(1)
	active = true


## The engine entry point (2026-06 migration): a `SkeletonModifier3D` under the
## figure's skeleton. The engine runs modifiers after the animation and in
## child order, so the foot solve lands on the pose the clips wrote this frame
## without depending on where the component happens to sit in the scene tree —
## and `influence` is the engine's own blend weight rather than a hand-rolled
## one. `_update` keeps the per-frame work drivable by the headless tests.
func _process_modification() -> void:
	_update(get_process_delta_time())


func _update(delta: float) -> void:
	if _skeleton == null or _model == null or not _model.is_inside_tree():
		return
	if not _near_camera():
		active = false
		return
	# The parent-basis cache is **per frame**. Within one frame the chain needs
	# it — the shin's solve reads the thigh this same frame just placed — but
	# across frames it is a lie: the hips are re-posed by the locomotion clip
	# every tick, so a remembered hip rotation is last frame's, and every
	# correction computed against it lands in the wrong direction. That is what
	# the single-bone unit test cannot see (it clears the cache) and what the
	# end-to-end numbers show as 10-30 cm of error and a 0.87 m lurch.
	_applied_global.clear()
	# Standstill measurement: the model's own planar speed, read from the
	# **interpolated** transform — the raw physics-tick position alternates
	# hit/miss across render frames (the same sampling trap the physics
	# interpolation project documented), and an unsmoothed gate on it flapped
	# at the deceleration tail: release/restore, re-plant/re-drop, over and
	# over — the "twitches twice before settling" the playtest caught. While
	# the figure stands still no clip writes the legs any more, so pins held
	# from the last stride would otherwise freeze the pose there forever (see
	# `_process_standstill`).
	var cur_origin: Vector3 = _model.get_global_transform_interpolated().origin
	var displacement := cur_origin - _last_model_pos
	_last_model_pos = cur_origin
	var standstill := false
	if not _pos_anchored:
		_pos_anchored = true
	else:
		displacement.y = 0.0
		standstill = _update_stillness(displacement, delta)
	_pelvis_prepare(delta, standstill)
	for i: int in SIDES.size():
		_process_foot(i, delta, standstill)


## One step of the standstill decision — pure enough to test without a
## camera: smooth the measured speed, then latch with hysteresis (enter below
## `still_speed` after `still_delay`, leave only above `still_resume_speed`).
## Latching is what makes the decay tail safe: between the thresholds the
## decision does not change, so the release/restore cannot flap.
func _update_stillness(displacement: Vector3, delta: float) -> bool:
	var measured := displacement.length() / maxf(delta, 1e-4)
	_planar_speed = lerpf(_planar_speed, measured,
		1.0 - exp(-still_speed_lerp * delta))
	if _still:
		if _planar_speed > still_resume_speed:
			_still = false
			_still_time = 0.0
			# Real motion again: the clips write the legs, so a restore in
			# progress would only fight them.
			_cancel_restore(0)
			_cancel_restore(1)
		elif _planar_speed > still_speed:
			# Between the thresholds the clips may already be walking again —
			# the latch only gates *planting*, not the clips — so a restore
			# still running here would mute the first strides and then hand
			# back a half-rest pose. Yield it early; the latch keeps planting
			# off until the resume speed either way.
			_cancel_restore(0)
			_cancel_restore(1)
	else:
		if _planar_speed < still_speed:
			_still_time += delta
			if _still_time >= still_delay:
				_still = true
				_still_time = 0.0
		else:
			_still_time = 0.0
	return _still


## Drop the pelvis once per frame by the **worst** shortfall among the feet the
## IK currently owns, so the two legs cannot compound their compensation.
##
## This runs after the locomotion clips — the component is the last child of the
## model, so its `_process` is last — which matters: it reads the hip the clip
## just posed and offsets it, rather than accumulating an offset of its own
## across frames. That is also why the correction is a per-frame recompute and
## not a stored baseline: the clip owns the hips, this component only leans on
## them.
func _pelvis_prepare(delta: float, standstill: bool = false) -> void:
	if _skeleton == null:
		return
	var hips: int = _skeleton.find_bone(HIPS_BONE)
	if hips < 0:
		return
	var hips_origin: Vector3 = _skeleton.get_bone_pose(hips).origin
	# Claim the bone. If the pose still holds exactly what we wrote last frame,
	# nobody re-posed the hips since (a stance frame with the clip idle) and
	# our old drop is still in there — strip it so the shortfall reading below
	# is the clip's own geometry. If the pose differs, the clips' absolute
	# write already retired our offset, and subtracting it again would cancel
	# the very drop this frame applies: the undo-then-apply pair netted zero
	# every locomotion frame, and the window probe measured the consequence as
	# a permanent ~0.19 m clamp shortfall and a held foot sliding at body
	# speed. The old undo presumed the hips pose *persists* between frames;
	# for a bone the clip positions absolutely, it does not.
	if _hips_written.length_squared() > 0.0 \
			and hips_origin.is_equal_approx(_hips_written):
		hips_origin = _hips_base
		_skeleton.set_bone_pose_position(hips, hips_origin)
	var worst: float = 0.0
	for side: int in SIDES.size():
		if _weight[side] <= 0.001:
			continue
		var chain: Dictionary = _chains[side]
		var upper: int = int(chain.get("upper", -1))
		var lower: int = int(chain.get("lower", -1))
		var foot: int = int(chain.get("foot", -1))
		if upper < 0 or lower < 0 or foot < 0:
			continue
		var l1: float = _rest_length(upper, lower)
		var l2: float = _rest_length(lower, foot)
		if l1 <= 0.0 or l2 <= 0.0:
			continue
		var to_target: Vector3 = _plant_pos[side] - _bone_origin(upper)
		var gap: float = to_target.length() - (l1 + l2)
		if gap > worst:
			worst = gap
	# Direction: **straight down in the model's own frame**, not "toward the
	# worst foot". The shortfall exists because the leg is shorter than the hip
	# is high, so down is the whole correction; taking the direction from
	# whichever foot happens to be worst made it flip between the two legs
	# stride by stride, and the smoothed offset then walked an arc — the pelvis
	# twitch reported in play (legs snapping forward, jerking seconds into a
	# run). A stable direction is worth more here than a geometrically exact
	# one.
	var direction: Vector3 = -_model.global_transform.basis.y.normalized()
	var want: Vector3 = Vector3.ZERO
	if worst > 0.0:
		want = direction * minf(worst, max_pelvis_drop)
	# Ease toward the goal. The shortfall breathes with the stride — the hips
	# rise and fall, the feet plant and lift, and the worst-foot identity swaps
	# sides — so a raw per-frame value wrote that breathing straight into the
	# pelvis as a twitch. Which foot is "worst" no longer decides the direction
	# frame to frame either: the offset itself is the state, and it is smoothed.
	# Ease in briskly, ease out slowly. The stance phase is short, so the drop
	# has to arrive during it; but cancelling it the instant the stance ends
	# snapped the figure back to centre (playtested as a flash back to the
	# middle of the frame), so leaving takes a third of the rate.
	var rising: bool = want.length_squared() > _pelvis_current.length_squared()
	var rate: float = pelvis_smoothing if rising else pelvis_smoothing * 0.3
	if standstill and not rising:
		# At standstill the restored legs are already at rest: a slow drain
		# would leave them brushing the ground under a still-lowered hip and
		# read as a second bob after the stop. Drain at the full rate — still
		# exponential, just one motion instead of two.
		rate = pelvis_smoothing
	_pelvis_current = _pelvis_current.lerp(want, 1.0 - exp(-rate * delta))
	# Apply the eased offset onto the clean hips pose. World → hips-pose needs
	# BOTH basis steps: the skeleton node's own basis (the authored 180° flip,
	# the run lean — `get_bone_global_pose` never sees node transforms, the
	# same trap `rig_rotation_fix` fixes for the swing axis) and then the
	# parent chain's basis. A yaw-only rig cancels the two yaws for a down
	# vector, which is why the missing node step stayed invisible this long.
	_hips_base = hips_origin
	if _pelvis_current.length_squared() > 0.0:
		var offset: Vector3 = _skeleton.global_transform.basis.inverse() \
			* _pelvis_current
		var parent := _skeleton.get_bone_parent(hips)
		if parent >= 0:
			offset = _skeleton.get_bone_global_pose(parent).basis.inverse() * offset
		var written: Vector3 = hips_origin + offset
		_skeleton.set_bone_pose_position(hips, written)
		_hips_written = written
		_applied_global[HIPS_BONE] = _skeleton.get_bone_global_pose(hips).basis
	else:
		_hips_written = hips_origin


func _near_camera() -> bool:
	var camera: Camera3D = _model.get_viewport().get_camera_3d()
	if camera == null:
		return false
	return camera.global_position.distance_to(_model.global_position) < active_range


func _process_foot(side: int, delta: float, standstill: bool = false) -> void:
	var chain: Dictionary = _chains[side]
	var foot: int = int(chain.get("foot", -1))
	if foot < 0:
		return
	if standstill:
		_process_standstill(side, delta)
		return
	var foot_pos: Vector3 = _bone_origin(foot)
	var ground: Variant = _ground_under(foot_pos)
	var clearance: float = INF
	if ground != null:
		clearance = foot_pos.y - (ground as Vector3).y - ANKLE_HEIGHT
	_clearance[side] = clearance
	_grounded[side] = ground != null
	var release_at: float = plant_exit if _planted[side] else plant_enter
	var keep_planting := true
	if ground == null or clearance > release_at:
		# Swing phase — the clip owns the foot. A real lift is also what
		# re-arms planting after a reach release: the foot has to rise above
		# the *landing* threshold before it may pin again. Requiring
		# `plant_exit` instead would permanently retire any foot whose swings
		# peak between the two thresholds — measured sprint swings run 0.2-0.4
		# m, and the shallow end of that band would never re-arm.
		keep_planting = false
		_planted[side] = false
		if ground == null or clearance > plant_enter:
			_reach_released[side] = false
	elif not _planted[side] and _reach_released[side]:
		# Still on the ground after a reach release: the pin is out of the
		# leg's reach, and re-pinning a dragging foot would just move the
		# anchor under it.
		keep_planting = false
	else:
		if not _planted[side]:
			_planted[side] = true
			# Pin to the **ground**, not to wherever the foot was when the
			# test fired. A landing frame catches the foot a few centimetres
			# up; pinning that height leaves the clearance hovering at the
			# threshold forever, the plant flag chatters, and every re-plant
			# re-pins the current position — which is the sliding this
			# component exists to remove.
			_plant_pos[side] = Vector3(foot_pos.x, (ground as Vector3).y + ANKLE_HEIGHT, foot_pos.z)
			_plant_time[side] = 0.0
		_plant_time[side] += delta
		# The pin must stay within what the leg plus the pelvis drop can
		# actually hold. Beyond that the reach clamp turns the plant into a
		# drag anchor: the ankle rides at full extension toward the pin and
		# scrapes along behind the body at ground level. Hand the foot back;
		# the next swing re-arms.
		var upper: int = int(chain.get("upper", -1))
		var lower: int = int(chain.get("lower", -1))
		if upper >= 0 and lower >= 0:
			var l1: float = _rest_length(upper, lower)
			var l2: float = _rest_length(lower, foot)
			if l1 > 0.0 and l2 > 0.0:
				var over: float = (_plant_pos[side] - _bone_origin(upper)).length() \
					- (l1 + l2)
				# `over` reads the hip *after* this frame's drop, so while the
				# drop is still easing in it understates the true shortfall —
				# keying the release on it alone waits out the easing while
				# the clamp drags (the walk-gear probe measured pins stuck at
				# 0.15 against a 0.16 threshold exactly this way). Project the
				# drop back in: the raw shortfall is what decides whether the
				# pin can ever be served.
				var raw_over: float = over + _pelvis_current.length()
				if raw_over > max_pelvis_drop + reach_exit:
					keep_planting = false
					_planted[side] = false
					_reach_released[side] = true
		# A pin older than `plant_max_time` is handed back as well — the stand
		# still gate covers the stopped figure, but a long stance on a slow
		# walk should not pin forever either.
		if keep_planting and _plant_time[side] > plant_max_time:
			keep_planting = false
			_planted[side] = false
	# A release hands the foot back to the clip as a **blend into the clip's
	# own pose for this frame** — the bones still hold it, because the clip
	# wrote them before this component runs. Two earlier shapes were wrong:
	# stopping the solve outright popped the leg back in one frame, and
	# fading a solve *toward the pin* pulled the leg backwards, because by
	# then the advancing body had left the pin behind (the periodic
	# back-kick during walks). The clip pose is the only anchor that is
	# never stale.
	if keep_planting:
		_weight[side] = move_toward(_weight[side], 1.0, blend_speed * delta)
		_release_from[side] = {}
		_release_t[side] = 0.0
	else:
		_weight[side] = move_toward(_weight[side], 0.0, blend_speed * delta)
		if _weight[side] > 0.001 and _release_from[side].is_empty():
			_begin_release(side)
	if _weight[side] <= 0.001:
		_release_from[side] = {}
		_release_t[side] = 0.0
		return
	if not _release_from[side].is_empty():
		_advance_release(side, delta)
		return
	_solve(side, _plant_pos[side], _weight[side])
	_ik_error[side] = (_bone_origin(int((_chains[side] as Dictionary)["foot"])) - _plant_pos[side]).length()


## Snapshot the written pose of one leg chain at the moment of a release —
## the source of the hand-off blend.
func _begin_release(side: int) -> void:
	var chain: Dictionary = _chains[side]
	var snapshot: Dictionary = {}
	for key: String in ["upper", "lower", "foot"]:
		var index: int = int(chain.get(key, -1))
		if index < 0:
			continue
		snapshot[key] = {
			"rot": _skeleton.get_bone_pose_rotation(index),
			"pos": _skeleton.get_bone_pose_position(index),
			"scale": _skeleton.get_bone_pose_scale(index),
		}
	_release_from[side] = snapshot
	_release_t[side] = 0.0


## One blended frame of the hand-off: each chain bone eases from the release
## snapshot toward the clip's current pose, smoothstepped so the first frame
## reproduces the snapshot exactly (no pop) and the last lands on the clip
## (no residual correction). Read-then-write per bone: the value read *is*
## the clip's write for this frame.
func _advance_release(side: int, delta: float) -> void:
	var chain: Dictionary = _chains[side]
	_release_t[side] += delta
	var weight := clampf(_release_t[side] / release_blend, 0.0, 1.0)
	var eased := weight * weight * (3.0 - 2.0 * weight)
	for key: String in ["upper", "lower", "foot"]:
		var index: int = int(chain.get(key, -1))
		if index < 0 or not _release_from[side].has(key):
			continue
		var from: Dictionary = _release_from[side][key]
		_skeleton.set_bone_pose_rotation(index, (from["rot"] as Quaternion).slerp(
			_skeleton.get_bone_pose_rotation(index), eased))
		_skeleton.set_bone_pose_position(index, (from["pos"] as Vector3).lerp(
			_skeleton.get_bone_pose_position(index), eased))
		_skeleton.set_bone_pose_scale(index, (from["scale"] as Vector3).lerp(
			_skeleton.get_bone_pose_scale(index), eased))


## Standstill: no clip is writing the legs any more, so this component is the
## only writer left — and that is the trap. A pin held from the last stride
## keeps the solve stretching the leg toward it forever: the reach and
## plant-time releases "hand the foot back to the clip", but a stopped clip
## never picks it up, and fading the weight to zero leaves the last written
## pose in place — the figure freezes mid-stride (reported as exactly that).
## Release the pin and ease the whole chain back to rest.
##
## The pelvis drop drains on its own once the weights read zero
## (`_pelvis_prepare` sums only owned sides), though on its slower fall rate —
## for a few tenths of a second the restored legs may brush the ground under a
## still-lowering hip. Measured acceptable; revisit with the drop rate if a
## playtest disagrees.
func _process_standstill(side: int, delta: float) -> void:
	# The hand-off blend targets the clip's pose, which no longer exists at
	# a standstill — the restore below owns the legs from here.
	_release_from[side] = {}
	_release_t[side] = 0.0
	_planted[side] = false
	if _weight[side] > 0.001:
		# This side's pose is the one this component last wrote — nobody else
		# will rewrite it, so the restore has to start from it. A side whose
		# weight is already zero was released while the clip still owned the
		# pose; the stop blend eases that one to rest.
		if _restore_from[side].is_empty():
			_begin_restore(side)
		_weight[side] = 0.0
	if not _restore_from[side].is_empty():
		_advance_restore(side, delta)


## Snapshot the written pose of one leg chain, as the restore blend's source.
func _begin_restore(side: int) -> void:
	var chain: Dictionary = _chains[side]
	var snapshot: Dictionary = {}
	for key: String in ["upper", "lower", "foot"]:
		var index: int = int(chain.get(key, -1))
		if index < 0:
			continue
		snapshot[key] = {
			"rot": _skeleton.get_bone_pose_rotation(index),
			"pos": _skeleton.get_bone_pose_position(index),
			"scale": _skeleton.get_bone_pose_scale(index),
		}
	_restore_from[side] = snapshot
	_restore_t[side] = 0.0


## One blended frame of the restore: every chain bone eases from the snapshot
## toward its rest pose with the stop blend's smoothstep. Done means clear —
## the empty dictionary is the "not restoring" flag. Before writing, the
## ownership check: if the bones no longer hold what the previous frame
## wrote, the stop blend has taken the legs over and this restore stands
## down instead of yanking them back to its own (older) trajectory.
func _advance_restore(side: int, delta: float) -> void:
	var chain: Dictionary = _chains[side]
	if not _restore_last[side].is_empty():
		for key: String in ["upper", "lower", "foot"]:
			var index: int = int(chain.get(key, -1))
			if index < 0 or not _restore_last[side].has(key):
				continue
			var last: Dictionary = _restore_last[side][key]
			var moved: bool = not _skeleton.get_bone_pose_rotation(index) \
				.is_equal_approx(last["rot"]) \
				or not _skeleton.get_bone_pose_position(index) \
				.is_equal_approx(last["pos"])
			if moved:
				_cancel_restore(side)
				return
	_restore_t[side] += delta
	var weight := clampf(_restore_t[side] / still_restore_time, 0.0, 1.0)
	var eased := weight * weight * (3.0 - 2.0 * weight)
	var written: Dictionary = {}
	for key: String in ["upper", "lower", "foot"]:
		var index: int = int(chain.get(key, -1))
		if index < 0 or not _restore_from[side].has(key):
			continue
		var rest := _skeleton.get_bone_rest(index)
		var from: Dictionary = _restore_from[side][key]
		var target_rot: Quaternion = (from["rot"] as Quaternion).slerp(
			rest.basis.get_rotation_quaternion(), eased)
		var target_pos: Vector3 = (from["pos"] as Vector3).lerp(
			rest.origin, eased)
		var target_scale: Vector3 = (from["scale"] as Vector3).lerp(
			rest.basis.get_scale(), eased)
		_skeleton.set_bone_pose_rotation(index, target_rot)
		_skeleton.set_bone_pose_position(index, target_pos)
		_skeleton.set_bone_pose_scale(index, target_scale)
		written[key] = {"rot": target_rot, "pos": target_pos,
			"scale": target_scale}
	_restore_last[side] = written
	if weight >= 1.0:
		_restore_from[side] = {}
		_restore_t[side] = 0.0
		_restore_last[side] = {}


func _cancel_restore(side: int) -> void:
	_restore_from[side] = {}
	_restore_t[side] = 0.0
	_restore_last[side] = {}


## The two-bone solve: put the foot on `target`, with `weight` deciding how much
## of the correction is applied (0 = leave the clip's pose alone).
##
## The thigh is aimed at a *constructed* direction: the hip→goal ray tilted off
## it by the law-of-cosines interior angle, toward the knee-forward side. That
## makes |goal − knee| equal the shin length by construction, so the shin's
## swing about the bend axis lands the ankle exactly — at any bend, including
## the fold where the knee passes the target. The two earlier shapes of this
## solve are both measured failures and worth remembering:
##
##   * Swing the thigh straight at the goal (the previous build): the knee lands
##     on the ray at l1, and the shin's single pivot can then bring the ankle no
##     closer than |l2 − |d − l1|| — ~7.4 cm short at a running stance
##     (d ≈ 0.65 against a 0.724 m chain), the whole gap in a deep fold. That
##     per-solve landing error, re-pinned every stride, is the 0.15-0.18 m/frame
##     full-weight drift the window probe measured.
##   * Apply the law-of-cosines angle to the animated leg directly (the first
##     cut before that): only valid from a straight start; a bent leg's chain
##     direction is not the target direction and the correction lands nowhere
##     near the foot — 10-30 cm of error.
##
## Both rotations remain *swing the current direction onto the wanted one*
## about the bend plane's normal, thigh first, shin measured after it lands.
## Residual known gap: a current direction carrying a bend-axis component
## (hip sway in the clips) keeps that component through the swing; the shin
## swing absorbs most of it, which is why the probe's acceptance is 1e-2 and
## not machine epsilon — though on a planar problem it reads ~1e-7.
func _solve(side: int, target: Vector3, weight: float) -> void:
	var chain: Dictionary = _chains[side]
	var upper: int = int(chain["upper"])
	var lower: int = int(chain["lower"])
	var foot: int = int(chain["foot"])
	if upper < 0 or lower < 0 or foot < 0:
		return
	# Bone length: the distance from this bone's origin to the next one's. (Not
	# the rest transform's Y axis — on this rig that reads 1.0 for every
	# bone, Godot storing rest rotations without scale.)
	var l1: float = _rest_length(upper, lower)
	var l2: float = _rest_length(lower, foot)
	if l1 <= 0.0 or l2 <= 0.0:
		return
	var hip: Vector3 = _bone_origin(upper)
	var to_target: Vector3 = target - hip
	if to_target.length() < 0.001:
		return
	# The pelvis has already been dropped this frame (`_pelvis_prepare`), so the
	# hip here is the compensated one and the goal is back inside the reach.
	_last_reach[side] = Vector3(l1, l2, to_target.length())
	# Clamp the goal into the chain's reach so the two swings stay consistent
	# instead of asking for a length the leg does not have.
	var reach: float = clampf(to_target.length(), absf(l1 - l2) + 0.001, l1 + l2 - 0.001)
	var goal: Vector3 = hip + to_target.normalized() * reach
	# The knee folds in a fixed plane so the legs always bend the same way
	# without the rig's rest axes leaking in. The sign matters and is not
	# guessable: the first build used the character's right axis and the
	# photographed result was a backwards knee (thigh straight down, shin
	# folded behind) — the rotations ran the wrong way round the bend.
	var bend_normal: Vector3 = -_model.global_transform.basis.x.normalized()
	if absf(bend_normal.dot(to_target.normalized())) > 0.99:
		bend_normal = _model.global_transform.basis.z.normalized()
	# Place the thigh where the *geometry* needs it: the ray toward the goal,
	# tilted off it by the interior hip angle toward the knee-forward side
	# (`KNEE_SIGN`). Tilted that way, |goal − knee| equals the shin length by
	# the law of cosines, so the shin's swing below is exact instead of falling
	# |l2 − |d − l1|| short (the measurements live in this function's header).
	# The same angle covers the fold: with the pin inside the thigh's reach the
	# interior angle exceeds a right angle, the knee swings sideways-front and
	# the ankle still lands on the pin — no separate fold guard needed. The
	# angle is computed from the clamped `reach`, the same length `goal` uses,
	# so goal and knee stay exactly one shin apart.
	var ray: Vector3 = (goal - hip).normalized()
	var alpha: float = two_bone_angles(l1, l2, reach).x
	var thigh_wanted: Vector3 = ray.rotated(bend_normal, KNEE_SIGN * alpha)
	var thigh_dir: Vector3 = (_bone_origin(lower) - hip).normalized()
	var thigh_angle: float = thigh_dir.signed_angle_to(thigh_wanted, bend_normal)
	_aim(upper, bend_normal, thigh_angle, weight)
	var knee_after: Vector3 = _bone_origin(lower)
	var shin_dir: Vector3 = (_bone_origin(foot) - knee_after).normalized()
	var shin_angle: float = shin_dir.signed_angle_to(
		(goal - knee_after).normalized(), bend_normal)
	_aim(lower, bend_normal, shin_angle, weight)
	_last_angles[side] = Vector2(thigh_angle, shin_angle)
	_last_goal[side] = goal


## Rotate one bone by `angle` about `axis`, blended in by `weight`, using the
## `parent_global · pose` convention documented at the top of the file.
func _aim(bone: int, axis: Vector3, angle: float, weight: float) -> void:
	if absf(angle) < 0.0001:
		return
	var name: String = _skeleton.get_bone_name(bone)
	var parent := _skeleton.get_bone_parent(bone)
	var parent_global: Basis = _applied_global.get(
		name if parent < 0 else _skeleton.get_bone_name(parent),
		# The **current** global pose, not the rest: the locomotion clip has
		# already moved the hips this frame, and solving against a stale rest
		# parent puts the correction in the wrong frame — it went unnoticed in
		# `ModelStance` only because a standing figure's rest *is* its pose.
		_skeleton.get_bone_global_pose(parent).basis if parent >= 0 else Basis.IDENTITY
	)
	var current: Basis = parent_global * _skeleton.get_bone_pose(bone).basis
	var applied_axis: Vector3 = axis
	if rig_rotation_fix:
		applied_axis = _skeleton.global_transform.basis.inverse() * axis
	var rotation := Quaternion(applied_axis.normalized(), angle)
	rotation = Quaternion.IDENTITY.slerp(rotation, weight)
	var correction := Basis(rotation)
	var pose: Basis = parent_global.inverse() * correction * current
	_skeleton.set_bone_pose_rotation(bone, pose.get_rotation_quaternion())
	_applied_global[name] = correction * current


## Hip and knee angles (radians) that put a two-bone chain's end at distance `d`,
## by the law of cosines, with the reach clamped so the chain never has to bend
## backwards or snap straight. `x` is the upper bone, `y` the knee bend.
static func two_bone_angles(l1: float, l2: float, d: float) -> Vector2:
	# The epsilon is a tenth of a millimetre: on a 0.4 m bone a 1 mm gap already
	# costs ~4° of knee bend, which is visible as a permanently bent knee.
	var reach: float = clampf(d, absf(l1 - l2) + 0.0001, l1 + l2 - 0.0001)
	var cos_knee: float = clampf(
		(l1 * l1 + l2 * l2 - reach * reach) / (2.0 * l1 * l2), -1.0, 1.0)
	var knee: float = PI - acos(cos_knee)
	var cos_hip: float = clampf(
		(l1 * l1 + reach * reach - l2 * l2) / (2.0 * l1 * reach), -1.0, 1.0)
	return Vector2(acos(cos_hip), knee)


# --- geometry helpers ------------------------------------------------------

## The bone's tail in world space: its origin plus the child offset that points
## the bone the way it points.
func _bone_tail(bone: int) -> Vector3:
	var global_pose := _skeleton.global_transform * _skeleton.get_bone_global_pose(bone)
	return global_pose.origin + global_pose.basis.y.normalized() \
		* _rest_length(bone, -1, true)


func _bone_origin(bone: int) -> Vector3:
	return (_skeleton.global_transform * _skeleton.get_bone_global_pose(bone)).origin


## Rest distance to `other` (or to this bone's own tail when `other` is -1).
func _rest_length(bone: int, other: int, own_tail: bool = false) -> float:
	var pose := _skeleton.get_bone_global_rest(bone)
	if own_tail:
		return pose.basis.y.length()
	if other < 0:
		return 0.0
	return pose.origin.distance_to(_skeleton.get_bone_global_rest(other).origin)


func _ground_under(from: Vector3) -> Variant:
	var space: PhysicsDirectSpaceState3D = _model.get_world_3d().direct_space_state
	if space == null:
		return null
	var query := PhysicsRayQueryParameters3D.create(
		from + Vector3.UP * ray_up, from - Vector3.UP * ray_down, 1)
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return null
	return hit.get("position", from) as Vector3


## The current correction weight of one side — read by the walk probe to prove
## feet stay put instead of proving it with a screenshot.
func foot_weight(side: int) -> float:
	return _weight[side] if side >= 0 and side < _weight.size() else 0.0


func is_planted(side: int) -> bool:
	return _planted[side] if side >= 0 and side < _planted.size() else false


## The chain lengths and goal distance the last solve worked with — a leg
## straightened by the reach clamp looks identical to a leg with no bend until
## you can see the numbers.
func last_reach(side: int) -> Vector3:
	return _last_reach[side] if side >= 0 and side < _last_reach.size() else Vector3.ZERO


## The pelvis offset currently in effect (world space). Its per-frame change is
## the twitch measurement: a value that jitters frame to frame is a pelvis that
## jitters, whatever the feet are doing.
func pelvis_offset() -> Vector3:
	return _pelvis_current


## The angles the last solve asked for — a near-zero pair means the goal is
## already where the leg is, i.e. nothing to correct, which is a different
## problem from a correction that fails to apply.
func last_angles(side: int) -> Vector2:
	return _last_angles[side] if side >= 0 and side < _last_angles.size() else Vector2.ZERO


func last_goal(side: int) -> Vector3:
	return _last_goal[side] if side >= 0 and side < _last_goal.size() else Vector3.ZERO


## Diagnostics for the walk probe: how high the foot sits over the ground, and
## whether the ground ray hit at all. A phase test that never fires looks
## identical to a broken one without these.
func last_clearance(side: int) -> float:
	return _clearance[side] if side >= 0 and side < _clearance.size() else 0.0


## Distance between where the solve aimed and where the foot actually landed.
## Large while planted means the two-bone solve is wrong; small with the foot
## still sliding means the measurement is.
func ik_error(side: int) -> float:
	return _ik_error[side] if side >= 0 and side < _ik_error.size() else 0.0


func ground_found(side: int) -> bool:
	return _grounded[side] if side >= 0 and side < _grounded.size() else false


## The foot's world position, for the same measurement.
func foot_world_pos(side: int) -> Vector3:
	if side < 0 or side >= _chains.size():
		return Vector3.ZERO
	var foot: int = int((_chains[side] as Dictionary).get("foot", -1))
	return _bone_origin(foot) if foot >= 0 else Vector3.ZERO
