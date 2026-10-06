extends RefCounted
class_name LocomotionStateTable
## The set of states a figure can be in, and the rules for choosing between
## them. One table, one clock: transition durations live on the states, so a
## new state arrives with its own timing already decided rather than as a
## parameter to hand-match against the others.
##
## ## What this is for
##
## The locomotion brain was `_decide_gear()`: a single function holding the
## ground case, the airborne case and the gear hysteresis, with the stop blend
## on one side and the walk gear on the other. It worked, and every number in
## it was earned by measurement — the gear hold, the landing's quiet-tick count,
## the airborne cross-fade. None of that is being redesigned here.
##
## What changes is *where the states live*. Today adding one means adding
## branches to that function, and the new state's transition time has to be
## guessed against three existing timers it cannot see
## (`ModelClips.stop_blend`, `ModelFootIK.still_restore_time` /
## `release_blend`, `ModelLean.ease_speed`). That is the mechanism behind the
## reported symptom: features that fit together individually but never settle
## into one smooth transition.
##
## So: the states are declared, each with its own blend time, and the clock
## reads it. A state that reads as "zero speed but not standing" (floating on
## water) becomes a row rather than a special case bolted onto the speed test.
##
## ## What is deliberately *not* here
##
## Entry conditions stay in `ModelClips`, unchanged and in the same order, with
## the same thresholds. They are physics decisions (is this body airborne, how
## long has it been quiet, how deep is the water) and they were tuned against
## the probes; moving them into a table would make them harder to compare with
## the numbers the probes record, not easier. The table owns *what a state is*,
## not *when to enter it*.

## The measured ground speeds and thresholds. Exported so the probes and the
## editor can still reach them, and so a future state row can refer to the
## same numbers rather than re-typing them.
var walk_threshold: float = 0.25
var run_threshold: float = 3.2
var rise_threshold: float = 1.5
var fall_threshold: float = -2.0
var land_threshold: float = -0.3

## The clip names this table's states name. Declared here as well so the table
## is self-contained; `ModelClips` keeps its own constants for the probes that
## reference them.
const WALK_CLIP: StringName = &"walk"
const RUN_CLIP: StringName = &"run"
const JUMP_CLIP: StringName = &"jump"
const FALL_CLIP: StringName = &"fall"

## States by name. The names are the ones the component switches on; the
## airborne phases keep the integers they already used (`_air_phase` is read by
## the probes) so nothing downstream has to learn a new vocabulary.
const IDLE: StringName = &"idle"
const WALK: StringName = &"walk"
const RUN: StringName = &"run"
const JUMP: StringName = &"jump"
const FALL: StringName = &"fall"
const FLOAT: StringName = &"float"

## The ground set, with the authored speeds and strides measured against the
## real body: the walk clip is honest at 1.3 m/s and the walk speed sits at
## 3.0 (rate 2.31, small strides, no clip slide), while sprint maps the run
## clip at ~2.5x.
var _states: Dictionary = {}

## One clock for every transition. Advanced by the component that owns the
## current transition; `ModelClips` and the foot IK read it instead of keeping
## their own. See `TransitionClock`.
var clock: TransitionClock = TransitionClock.new()


func _init() -> void:
	_states[IDLE] = LocomotionState.make(
		&"", LocomotionState.Pace.SPEED_TRACKED, 0.18, LocomotionState.Footwork.PLANTED
	)
	_states[WALK] = LocomotionState.make(
		WALK_CLIP, LocomotionState.Pace.SPEED_TRACKED, 0.18, LocomotionState.Footwork.PLANTED
	)
	_states[RUN] = LocomotionState.make(
		RUN_CLIP, LocomotionState.Pace.SPEED_TRACKED, 0.1, LocomotionState.Footwork.PLANTED
	)
	# The leap is an action, not a loop: it plays once and holds the tuck.
	_states[JUMP] = LocomotionState.make(
		JUMP_CLIP, LocomotionState.Pace.ONCE, 0.1, LocomotionState.Footwork.FREE
	)
	# The fall loops, and picks up pace with the descent.
	_states[FALL] = LocomotionState.make(
		FALL_CLIP, LocomotionState.Pace.FALL_TRACKED, 0.1, LocomotionState.Footwork.FREE
	)
	# Floating: no stride to play and no ground to stand on. It exists in the
	# table from the start so the "zero speed is not necessarily standing" case
	# is a row rather than a special case — a body drifting on the water reads
	# speed as zero, which used to mean *stopped* and played a standing pose.
	_states[FLOAT] = LocomotionState.make(
		&"", LocomotionState.Pace.SPEED_TRACKED, 0.25, LocomotionState.Footwork.FREE
	)
	var walk := _states[WALK] as LocomotionState
	walk.authored_speed = 1.3
	walk.rate_min = 0.6
	walk.rate_max = 2.4
	var run := _states[RUN] as LocomotionState
	run.authored_speed = 3.4
	run.rate_min = 0.6
	run.rate_max = 2.5
	var fall := _states[FALL] as LocomotionState
	fall.fall_reference = 4.0
	fall.fall_rate_min = 0.9
	fall.fall_rate_max = 2.2
	# Arriving on the ground is quicker than leaving it: the ground has already
	# absorbed the fall, so a long fade reads as a bounce. The stop blend is the
	# same transition the landing uses — measured to be the right shape — so
	# both ends share the time.
	var idle := _states[IDLE] as LocomotionState
	idle.exit_blend_time = 0.18


## Look a state up. Returns null for an unknown name so a caller can hold its
## own fallback rather than writing through a missing key.
func get_state(id: StringName) -> LocomotionState:
	return _states.get(id, null) as LocomotionState


func has_state(id: StringName) -> bool:
	return _states.has(id)


func add_state(id: StringName, state: LocomotionState) -> void:
	_states[id] = state


## Every declared state, in declaration order. For probes and the debug panel.
func ids() -> Array[StringName]:
	var result: Array[StringName] = []
	for id: StringName in _states:
		result.append(id)
	return result