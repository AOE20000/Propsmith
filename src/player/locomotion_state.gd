extends RefCounted
class_name LocomotionState
## One locomotion state, declared. A state is a *clip choice plus how to get
## there and out*, nothing more — the transitions between states live in
## `LocomotionStateTable`.
##
## Why this exists: the locomotion brain used to be one function with the
## ground case and the airborne case hard-wired into each other, and the
## transition *durations* scattered across three components that could not see
## each other (`ModelClips.stop_blend`, `ModelFootIK.still_restore_time` /
## `release_blend`, `ModelLean.ease_speed`). Adding a state meant editing that
## function's branches and then hand-matching a new timer against two existing
## ones — which is why the timing never quite settled.
##
## A state carries its own blend time, so the clock has one source to read and
## a new state brings its transition with it.
##
## `blend_time` is the way *into* this state; `exit_blend_time` is the way out,
## for the few states whose departure wants to be quicker than their arrival
## (a landing reads better snapping to the stance than easing into it — the
## ground has already absorbed the fall, so a long fade there reads as a bounce).
## Leave it at -1.0 to use `blend_time`.

## The clip this state plays. Empty for a state that plays no clip (a float on
## water has no stride to loop).
var clip: StringName = &""
## How the sampler should advance the clip. A locomotion loop tracks ground
## speed; an airborne action does not (the leap is 0.21 s of authored time and
## the rise lasts half a second, so it plays once and holds).
enum Pace {
	## Playback rate follows measured ground speed, divided by the state's
	## authored speed and clamped to the clip's believable stride range.
	SPEED_TRACKED,
	## Play once at the authored rate and hold the last frame.
	ONCE,
	## Loop at a rate derived from |vertical speed| — a long fall reads better
	## picked up than a slow descent drifting through the cycle.
	FALL_TRACKED,
}
var pace: Pace = Pace.SPEED_TRACKED
## For SPEED_TRACKED: the speed this clip was authored for (m/s). Playback
## rate = measured / this.
var authored_speed: float = 1.3
## For SPEED_TRACKED: the rate clamp. A cycle played far past its authored
## cadence reads as a moonwalk; too slow reads as a wade.
var rate_min: float = 0.6
var rate_max: float = 2.4
## For FALL_TRACKED: descent speed that maps to `rate_max`, and the floor.
var fall_reference: float = 4.0
var fall_rate_min: float = 0.9
var fall_rate_max: float = 2.2
## Seconds to blend into this state from whatever held the pose before.
var blend_time: float = 0.18
## Seconds to blend out; -1.0 means "same as blend_time".
var exit_blend_time: float = -1.0
## What this state does to the pose it does not own.
enum Footwork {
	## Nothing — the state holds no clips and leaves the bones alone.
	NONE,
	## Clips own the legs: no planting (the figure is off the ground).
	FREE,
	## Feet should stay planted if they can reach: run the foot IK.
	PLANTED,
}
var footwork: Footwork = Footwork.NONE
## Whether the procedural stance should keep writing while this state plays.
## False for every clip-playing state (the clip owns the pose and the stance's
## breathing would fight it); true for states that play no clip, which is
## precisely what the stance is for.
var stance_owns_pose: bool = false

## The blend time leaving this state — resolving the -1.0 sentinel once, here,
## so no caller has to remember the convention.
func exit_blend() -> float:
	return blend_time if exit_blend_time < 0.0 else exit_blend_time


static func make(
		p_clip: StringName,
		p_pace: Pace,
		p_blend: float,
		p_footwork: Footwork
	) -> LocomotionState:
	var state := LocomotionState.new()
	state.clip = p_clip
	state.pace = p_pace
	state.blend_time = p_blend
	state.footwork = p_footwork
	# A clip-playing state always suppresses the stance: it owns the pose.
	state.stance_owns_pose = p_clip == &""
	return state