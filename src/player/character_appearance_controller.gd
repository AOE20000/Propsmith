extends Node
class_name CharacterAppearanceController
## Owns the player's `CharacterState`: applies it to the attached humanoid,
## re-applies on every panel edit, and persists through the save system as its
## own section (`player_appearance`) so a save keeps the look that made it.
##
## Lives under the Player but reads nothing from it — the panel edits state
## through `set_option`, and the model is whatever `attach` was handed. When
## the Configura scene is missing (no import, no Blender) the controller still
## runs: the look is kept and applied the moment a model appears.

## The humanoid root currently wearing the state, if any. The state is built
## eagerly — `PlayerScene.build()` attaches the model before the player enters
## the tree, so `_ready` would be too late to have a look to apply.
var _model: Node3D = null
var _state: CharacterState = CharacterAppearance.default_state()


func _ready() -> void:
	SaveSystem.register_persistent(&"player_appearance", serializable, restore)


## Take over a freshly instantiated humanoid: apply the current look and start
## the idle clip so the character breathes instead of holding an A-pose.
func attach(model: Node3D) -> void:
	_model = model
	apply_current()
	_play_idle(model)


func current_state() -> CharacterState:
	return _state


## The model currently wearing the state. UIs ask rather than assume — the
## panel builds its shape-key section only when the model can honour it.
func model() -> Node3D:
	return _model


## One panel edit: record, re-apply, done. Cheap by design — every apply is a
## handful of `visible` flips and material writes, so there is no debounce.
func set_option(option_id: String, value: Variant) -> void:
	_state.record(option_id, value)
	apply_current()
	Events.appearance_edited.emit()


## Whole-state swap for the panel's randomize / reset buttons; the previous
## state is discarded, not merged, so "random" always reads as a new look.
func replace_state(state: CharacterState) -> void:
	if state == null:
		return
	_state = state
	apply_current()
	Events.appearance_edited.emit()


## Re-drive the whole state into the model. Missing model → state is kept and
## applied by the next attach; missing meshes inside the model are skipped.
## Shape-key sliders ride the same state and the same call: the component on
## the model (attached by `FigureAttachments.attach_all` when the model has the curated shapes)
## picks up its ids and ignores everything else.
func apply_current() -> void:
	CharacterAppearance.apply(_state, _model)
	ModelBlendShapes.apply_state(_model, _state.values)


func serializable() -> Dictionary:
	var encoded: Dictionary = {}
	for id: String in _state.values:
		encoded[id] = SaveSystem.encode_variant(_state.values[id])
	return {"values": encoded}


## Restore from a save. Unknown or missing keys fall back to the curated
## defaults rather than half a look — an old save predating an option must not
## show all thirteen hairstyles at once. Shape-key slider ids are merged into
## the defaults first, so a save written before they existed loads with the
## authored body instead of losing the ids.
func restore(data: Dictionary) -> void:
	var merged := CharacterAppearance.default_state()
	ModelBlendShapes.merge_defaults(merged)
	var raw: Variant = data.get("values", null)
	if raw is Dictionary:
		for id: Variant in (raw as Dictionary):
			var decoded: Variant = SaveSystem.decode_variant((raw as Dictionary)[id])
			if decoded != null and merged.values.has(String(id)):
				merged.values[String(id)] = decoded
	_state = merged
	apply_current()


## Play the imported idle clip on loop. The example model's clip is "Idle" —
## the glTF name "Idle_loop" loses its loop suffix in the Blender import — so
## the exact name is tried first and any name containing "idle" second, which
## also gives a renamed mod model its best chance. A model without an idle
## clip simply stays in its rest pose.
func _play_idle(model: Node) -> void:
	var player := model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if player == null:
		return
	var animation_name := &""
	if player.has_animation(&"Idle"):
		animation_name = &"Idle"
	else:
		for candidate: String in player.get_animation_list():
			if candidate.to_lower().contains("idle"):
				animation_name = StringName(candidate)
				break
	if animation_name == &"":
		return
	var animation := player.get_animation(animation_name)
	if animation != null:
		animation.loop_mode = Animation.LOOP_LINEAR
	player.play(animation_name)
