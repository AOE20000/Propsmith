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


## Apply the on-demand configuration to a freshly instantiated figure.
static func configure(model: Node3D) -> void:
	if model == null:
		return
	for node: Node in model.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		mesh_instance.visibility_range_end = VISIBILITY_RANGE
		if mesh_instance.name in SHADOW_CASTERS:
			mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		else:
			mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
