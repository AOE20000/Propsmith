extends Node
## Deterministic frame probe for `ModelFootIK`'s two-bone solve.
##
## Every frame is an *independent* solve against one world pin: reset the leg,
## place the rig, clear the chain cache, run `_solve`, measure the ankle. The
## "walk" is a sawtooth sweep of rig offsets, not a loop — there is no carried
## state, so each frame is reproducible and each scenario a pure function of
## its inputs. The pin never leaves the chain's reach, which removes the
## out-of-range clamp the first version of this probe waded into: there, the
## rig walked away from a fixed pin until the reach clamp pinned the error
## growth, and the numbers described the clamp, not the solve.
##
## Scenarios (chain l1 = l2 = 0.45 m, hip 0.5 m under the rig root):
##
##   A   static pin at d = 0.30 < l1  — the deep fold: the old solve lost the
##                                      whole gap (err = d); the cosine solve
##                                      must land the ankle on the pin
##   A2  static pin at d = 0.70       — the running-stance fold, mid-chain
##   B   identity rig, pin swept ±0.35 m — a stance passing over its pin
##   C   rig yawed 90°, fix OFF       — the conjugation contrast: the bend axis
##                                      is built in world space but applied
##                                      through skeleton-local bases, so a
##                                      rotated rig must break it
##   C2  rig yawed 90°, fix ON        — same sweep, conjugated axis
##   D   identity + a fake clip overwriting the thigh each frame, fix ON — the
##       real loop: the solve must win over whatever the clip just wrote
##
## The yawed scenarios sweep the rig along its **own forward** (world x at yaw
## 90°), like a real stance: the goal plane then stays perpendicular to the
## bend axis. That is the geometry a fixed-axis two-bone solve is exact in —
## and the only one the game produces, since the pin hangs below the hip and
## the bend normal is lateral. Sweeping *across* the bend axis would demand
## out-of-plane knee travel no fixed-axis solve can deliver, by design.
##
## In skeleton-local terms B and C2 are the *same* problem (same local pin
## offset, same local bend axis, same rest pose) — which the fix is supposed
## to make true in world space too. So the strongest assertions here are the
## per-frame identities: C2 and D must reproduce B's error frame for frame,
## and C (fix OFF) must stay an order of magnitude worse than C2.

const PIN_CLOSE: Vector3 = Vector3(0.0, -0.8, 0.0)  # 0.30 m under the hip
const PIN_FAR: Vector3 = Vector3(0.0, -1.2, 0.0)    # 0.70 m under the hip
## Sweep offsets: frame k of a walk scenario places the rig at
## AMPLITUDE - 2 * AMPLITUDE * k / (FRAMES - 1) along the scenario's axis —
## one pass from one extreme to the other.
const FRAMES: int = 20
const AMPLITUDE: float = 0.35
## The acceptance line for a landed ankle.
const TOLERANCE: float = 0.01
## Frames that solve the identical local problem must agree to float noise.
## The conjugation path multiplies through yaw sines/cosines, so the noise
## floor is ~1e-8 rather than machine epsilon — four orders under TOLERANCE.
const FRAME_MATCH: float = 1e-6

var _ik: ModelFootIK = null
var _skel: Skeleton3D = null
var _rig: Node3D = null
var _fails: int = 0
## tag -> worst error over the scenario (single frame for the statics).
var _worst: Dictionary = {}
## tag -> per-frame errors, for the cross-scenario identities.
var _trace: Dictionary = {}


func _ready() -> void:
	_build_rig()
	_ik.setup(_rig)
	_ik.rig_rotation_fix = true

	print("[fik-probe] A deep fold, static (d=0.30 < l1):")
	_run_static(PIN_CLOSE, "A")

	print("[fik-probe] A2 stance fold, static (d=0.70, chain 0.90):")
	_run_static(PIN_FAR, "A2")

	print("[fik-probe] B identity rig, pin swept under it:")
	_run_sweep(Vector3.ZERO, Vector3(0, 0, 1), "B", true)

	print("[fik-probe] C yawed 90, rotation fix OFF (must fail):")
	_ik.rig_rotation_fix = false
	_run_sweep(Vector3(0, PI / 2.0, 0), Vector3(1, 0, 0), "C", false)
	_ik.rig_rotation_fix = true

	print("[fik-probe] C2 yawed 90, rotation fix ON:")
	_run_sweep(Vector3(0, PI / 2.0, 0), Vector3(1, 0, 0), "C2", true)

	print("[fik-probe] D identity + clip overwrite each frame, fix ON:")
	_run_sweep(Vector3.ZERO, Vector3(0, 0, 1), "D", true, true)

	_cross_checks()

	if _fails == 0:
		print("[fik-probe] PASS all scenarios")
		get_tree().quit(0)
	else:
		print("[fik-probe] FAIL %d assertion(s)" % _fails)
		get_tree().quit(1)


## One solve, one measurement: the static scenarios pin the acceptance for the
## fold regimes without a sweep diluting them.
func _run_static(pin: Vector3, tag: String) -> void:
	_rig.rotation = Vector3.ZERO
	_rig.position = Vector3.ZERO
	_reset_leg(pin)
	_ik._applied_global.clear()
	_ik._solve(0, pin, 1.0)
	var error: float = _check_frame(pin, tag, -1, true)
	_worst[tag] = error
	_trace[tag] = PackedFloat64Array([error])


func _run_sweep(yaw: Vector3, axis: Vector3, tag: String, assert_green: bool,
		fake_clip: bool = false) -> void:
	_rig.rotation = yaw
	var worst: float = 0.0
	var trace := PackedFloat64Array()
	trace.resize(FRAMES)
	for frame: int in FRAMES:
		var offset: float = AMPLITUDE \
			- 2.0 * AMPLITUDE * float(frame) / float(FRAMES - 1)
		_rig.position = axis * offset
		_reset_leg(PIN_CLOSE)
		_ik._applied_global.clear()
		if fake_clip:
			# The clip's pose for this frame: the thigh swings, the chain leaves
			# rest — then the IK must win. About Vector3.RIGHT the damage stays
			# in the bend plane, so it bends the start state, not the plane.
			_skel.set_bone_pose_rotation(_skel.find_bone("LeftUpperLeg"),
				Basis(Quaternion(Vector3.RIGHT, 0.5)))
		_ik._solve(0, PIN_CLOSE, 1.0)
		var error: float = _check_frame(PIN_CLOSE, tag, frame, assert_green)
		trace[frame] = error
		worst = maxf(worst, error)
	_worst[tag] = worst
	_trace[tag] = trace
	print("[fik-probe] %s worst err over the sweep: %.6f m" % [tag, worst])


## Measure, report, and (when the scenario is supposed to work) assert. Returns
## the frame's error so the sweep can track its worst.
func _check_frame(pin: Vector3, tag: String, frame: int, assert_green: bool) -> float:
	var ankle: Vector3 = _ik._bone_origin(_skel.find_bone("LeftFoot"))
	var error: float = ankle.distance_to(pin)
	var knee_fwd: float = _knee_forward()
	var tag_frame: String = ("%s final" % tag) if frame < 0 \
		else ("%s f%02d" % [tag, frame])
	print("[fik-probe]   %s err=%.6f knee_fwd=%+.3f" % [tag_frame, error, knee_fwd])
	if assert_green:
		_expect(error < TOLERANCE, "%s must land the ankle on the pin" % tag_frame)
		_expect(knee_fwd > 0.0,
			"%s must fold the knee toward the model front" % tag_frame)
	return error


## Signed distance of the knee from the model-front plane through the hip.
## Positive = knee on the forward side, which is where a knee belongs.
func _knee_forward() -> float:
	var hip: Vector3 = _ik._bone_origin(_skel.find_bone("LeftUpperLeg"))
	var knee: Vector3 = _ik._bone_origin(_skel.find_bone("LeftLowerLeg"))
	return (knee - hip).dot(-_rig.global_transform.basis.z)


## The judgements no single frame can make: the conjugation fix must make the
## yawed rig reproduce the identity rig frame for frame, the clip overwrite
## must not survive the solve, and the fix must be what separates C from C2.
func _cross_checks() -> void:
	var b: PackedFloat64Array = _trace.get("B", PackedFloat64Array())
	var c2: PackedFloat64Array = _trace.get("C2", PackedFloat64Array())
	var d: PackedFloat64Array = _trace.get("D", PackedFloat64Array())
	var worst_gap_c2: float = 0.0
	var worst_gap_d: float = 0.0
	for frame: int in mini(b.size(), mini(c2.size(), d.size())):
		worst_gap_c2 = maxf(worst_gap_c2, absf(c2[frame] - b[frame]))
		worst_gap_d = maxf(worst_gap_d, absf(d[frame] - b[frame]))
	print("[fik-probe] B vs C2 worst frame gap: %.9f m" % worst_gap_c2)
	print("[fik-probe] B vs D  worst frame gap: %.9f m" % worst_gap_d)
	_expect(worst_gap_c2 < FRAME_MATCH,
		"the conjugation fix must make the yawed rig match the identity rig")
	_expect(worst_gap_d < FRAME_MATCH,
		"the solve must fully override the clip overwrite at full weight")
	var c_worst: float = float(_worst.get("C", 0.0))
	var c2_worst: float = maxf(float(_worst.get("C2", 0.0)), 1e-4)
	print("[fik-probe] contrast C=%.4f vs C2=%.6f (x%.0f)" % [
		c_worst, c2_worst, c_worst / c2_worst])
	_expect(c_worst > 0.05,
		"without the fix the yawed rig must miss the pin by centimetres")
	_expect(c_worst > 10.0 * c2_worst,
		"the fix must be worth an order of magnitude on the yawed rig")


## Hand the leg back to the "clip": poses to rest, planted state as the process
## loop would hold it mid-stance, pinned to `pin`. The rig transform is *not*
## touched — the sweep owns it.
func _reset_leg(pin: Vector3) -> void:
	_skel.reset_bone_poses()
	_ik._planted[0] = true
	_ik._plant_pos[0] = pin
	_ik._weight[0] = 1.0


## hips → thigh → shin → foot, each bone 0.45 m straight down, the VRM names
## `setup` looks for. Hip origin sits 0.05 m below the rig root.
func _build_rig() -> void:
	_rig = Node3D.new()
	_rig.name = "FootRig"
	add_child(_rig)
	_skel = Skeleton3D.new()
	_rig.add_child(_skel)
	var hips: int = _skel.add_bone("Hips")
	_skel.set_bone_rest(hips, Transform3D(Basis(), Vector3(0.0, -0.05, 0.0)))
	var thigh: int = _skel.add_bone("LeftUpperLeg")
	_skel.set_bone_parent(thigh, hips)
	_skel.set_bone_rest(thigh, Transform3D(Basis(), Vector3(0.0, -0.45, 0.0)))
	var shin: int = _skel.add_bone("LeftLowerLeg")
	_skel.set_bone_parent(shin, thigh)
	_skel.set_bone_rest(shin, Transform3D(Basis(), Vector3(0.0, -0.45, 0.0)))
	var foot: int = _skel.add_bone("LeftFoot")
	_skel.set_bone_parent(foot, shin)
	_skel.set_bone_rest(foot, Transform3D(Basis(), Vector3(0.0, -0.45, 0.0)))
	_skel.reset_bone_poses()
	_ik = ModelFootIK.new()
	_ik.name = "FootIK"
	add_child(_ik)


func _expect(condition: bool, what: String) -> void:
	if condition:
		return
	_fails += 1
	print("[fik-probe] ASSERT FAILED: %s" % what)
