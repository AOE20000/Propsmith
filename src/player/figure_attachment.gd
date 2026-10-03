extends RefCounted
class_name FigureAttachments
## The per-figure component stack, attachable to *any* humanoid figure — the
## player's, a citizen's, a probe's — with the same rules everywhere:
##   * no usable body clip  → `ModelStance`      (procedural stance)
##   * curated shape keys   → `ModelBlendShapes` (figure sliders)
##   * locomotion library   → `ModelClips`       (authored walk)
## Extracted from `PlayerScene`, which had become the module everyone pulled
## attachments through — mobility, the panel probe and the boot all need this
## stack, and none of them should know the player scene to get it.

## A body with no clip holds its authored T-pose forever. The base figure VRM
## ships without animation; the built-in Configura body plays its own `Idle`.
## So: if the chosen model carries no usable clip, hand it a procedural stance
## (arms down, shallow breathing) — that is the whole difference between "a
## character standing" and "an unposed rig" from the player's own camera.
##
## Clip-carrying models are left untouched, which makes this self-retiring: once
## a real idle is retargeted onto the VRM, the branch simply stops applying.
##
## Only *transform* tracks count as animation — a VRM arrives with about two
## dozen clips (`RESET` plus one per expression: `blink`, `aa`, `happy`,
## `lookUp`) and they animate blend shapes, not limbs. Testing for "any clip at
## all" would read a T-posed mannequin as fully animated, which is how the first
## VRM body shipped.
##
## Eye bones are the second exception. The VRM importer mirrors every expression
## into a clip that *also* rotates `LeftEye`/`RightEye` (its look-at rig), so even
## a transform-track test passes on a rig whose arms never move. Eyes cannot put
## the arms down, so they do not count as animation here.
const STANCE_IGNORED_BONES: PackedStringArray = ["eye"]


## Attach the full stack in the canonical order (stance → shape keys →
## locomotion clips). Order matters only for tree position, which decides
## per-frame write order; the components are written not to fight each other,
## but keeping one canonical order makes that reasoning local.
static func attach_all(model: Node3D) -> void:
	attach_stance_if_unanimated(model)
	attach_blend_shapes(model)
	attach_locomotion(model)


static func attach_stance_if_unanimated(model: Node3D) -> void:
	for node: Node in model.find_children("*", "AnimationPlayer", true, false):
		var player := node as AnimationPlayer
		if player == null:
			continue
		for clip: StringName in player.get_animation_list():
			if clip == &"RESET":
				continue
			if clip_animates_body(player.get_animation(clip)):
				return
	var stance := ModelStance.new()
	stance.name = "Stance"
	model.add_child(stance)
	stance.setup(model)


## A morph-carrying model gets the shape-key look component: the panel's figure
## sliders drive blend shapes, which no animation can stomp and no bone
## convention can break (bone-rest editing was measured to do nothing to a
## glTF-skinned model in Godot). Attached only when the model actually has the
## curated shapes — the panel uses the component's presence to decide whether
## to show the shape-key section at all, so a Configura or capsule model hides
## it instead of showing dead controls.
static func attach_blend_shapes(model: Node3D) -> void:
	if not ModelBlendShapes.has_curated_shapes(model):
		return
	var component := ModelBlendShapes.new()
	component.name = "BlendShapes"
	model.add_child(component)
	component.setup(model)


## Locomotion clips (walk/idle from the open animation library): the component
## measures the figure's actual velocity and plays the walk cycle while it
## moves, restoring the procedural stance when it stops. Attached only when
## the library and a player exist — everything else keeps the stance-only look.
static func attach_locomotion(model: Node3D) -> void:
	if not ResourceLoader.exists(ModelClips.LIBRARY_PATH):
		return
	var component := ModelClips.new()
	component.name = "Clips"
	model.add_child(component)
	component.setup(model)


## Whether *any* track in this animation moves a bone that matters. Blend-shape
## tracks (expressions) and eye-bone tracks (the importer's look-at rig) do not
## count — a figure whose only clips animate cheeks and eyeballs is still a
## T-posed mannequin to the player.
static func clip_animates_body(animation: Animation) -> bool:
	for track: int in animation.get_track_count():
		match animation.track_get_type(track):
			Animation.TYPE_POSITION_3D, Animation.TYPE_ROTATION_3D, \
			Animation.TYPE_SCALE_3D:
				# Bone tracks read "Skeleton3D:BoneName"; a blend-shape track
				# reads "Skeleton/Mesh:keyName" and is a different track type.
				var bone := String(animation.track_get_path(track)).get_slice(":", 1)
				var ignored := false
				for needle: String in STANCE_IGNORED_BONES:
					if bone.to_lower().contains(needle):
						ignored = true
						break
				if not ignored:
					return true
			_:
				pass
	return false
