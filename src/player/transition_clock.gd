extends RefCounted
class_name TransitionClock
## One clock for every pose transition on a figure.
##
## ## Why
##
## Three components were each keeping their own notion of how long a pose
## change takes, and none could see the others:
##
##   * `ModelClips.stop_blend` (0.18 s) — how long the deceleration reads
##   * `ModelFootIK.still_restore_time` (0.18 s), `release_blend` (0.12 s) — how
##     long the foot takes to hand the leg back and to recover
##   * `ModelLean.ease_speed` (7/s, ≈0.35 s tail) — how long the torso takes to
##     arrive and to settle
##
## Each was tuned against the others by eye and each was defensible alone, but
## together they meant the figure was running three independent accounts of one
## transition: reaching a stop, or turning, meant the legs, the torso and the
## blend were each finishing on their own schedule. That reads as the reported
## "it twitches, and then it settles" rather than as one deceleration.
##
## The fix is not to make the numbers agree — it is to stop having three
## questions. A component that needs to know "how long is this transition"
## asks the clock, and the clock answers from the state that is being entered
## (see `LocomotionState.blend_time`), so the answer and the state that caused
## it cannot drift apart.
##
## ## What it does *not* do
##
## It does not interpolate anything. Blending is still the writing component's
## job (`ModelClips._advance_stop_blend` slerps, the foot IK eases). The clock
## only owns *when* — which keeps it a plain value object that the headless
## tests can advance by hand, with no engine state to stand up.

## The elapsed time of the transition in progress (seconds).
var elapsed: float = 0.0
## How long that transition is (seconds). Set from the state being entered.
var duration: float = 0.0
## Whether a transition is running.
var running: bool = false


## Begin a transition of `duration` seconds. A zero or negative duration is
## treated as instant: the caller should apply the end pose immediately, which
## `finish_now()` does for it.
func begin(duration_seconds: float) -> void:
	duration = maxf(0.0, duration_seconds)
	elapsed = 0.0
	running = duration > 0.0
	if not running:
		finish_now()


## Abandon the transition without reaching the end. The next write lands at full
## weight — which is the correct response to the figure being teleported or the
## clips being forced by a probe, not eased from a pose that is no longer
## relevant.
func cancel() -> void:
	running = false
	elapsed = 0.0
	duration = 0.0


## Land the transition immediately.
func finish_now() -> void:
	elapsed = duration
	running = false


## Advance by `delta` and return the eased weight in [0, 1].
##
## Smoothstep, not a linear ramp: a linear blend reads as a mechanical snap at
## both ends, and the deceleration is the transition the player watches most
## closely — it is the one that has to sell the figure's weight.
func advance(delta: float) -> float:
	if not running:
		return 1.0
	elapsed += delta
	if elapsed >= duration:
		finish_now()
		return 1.0
	return weight()


## The transition's progress in [0, 1], eased.
func weight() -> float:
	if duration <= 0.0:
		return 1.0
	var t := clampf(elapsed / duration, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


## Seconds left, for telemetry and for components that pace themselves off the
## tail (the lean's arrival has to lead the legs' recovery, not match it).
func remaining() -> float:
	return maxf(0.0, duration - elapsed)


## True while the transition is still visibly moving. Components that must not
## interrupt a transition in flight (a second gear switch landing mid-fade)
## ask this.
func in_progress() -> bool:
	return running