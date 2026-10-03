extends Node
class_name ModelBlendShapes
## Shape-key driven look of a morph-carrying model (the CC0 base figure).
##
## The base figure's proportions live in its 93 body morphs — `All_Slim` /
## `All_M` / `All_L` as the coarse dials, the breast set, and a long tail of
## per-region and clothing-helper keys. Sliders here drive those directly via
## `MeshInstance3D.set_blend_shape_value`, which no animation can stomp and no
## bone convention can break. (Bone-rest editing was measured to do *nothing*
## to a glTF-skinned model in Godot — `get_bone_global_pose` keeps returning
## scale 1.0 no matter what the rest says — so morphs are the reliable channel.)
##
## The catalog is explicit by design, suffix parsing is a trap on this asset:
## `_L` means *Large* in the shape-key families but *Left* in the `_OFF` set,
## and the asset even ships a typo (`UppreArm_M`). The `_OFF` and `Nail_*`
## keys are deliberately absent — they are clothing helpers (hide-the-limb and
## UV swaps), not look controls, and belong to the clothing step.
##
## The component is attached to a model root only when the model actually has
## these shapes (see `PlayerScene._attach_blend_shapes`); its presence is the
## UI's signal to show the shape-key section at all.

## Slider catalog, grouped for the panel. Every entry names its mesh and shape
## explicitly; a model missing either simply does not resolve that slider.
const SLIDER_GROUPS: Dictionary = {
	&"figure": {
		"label": "体形",
		"sliders": [
			{"id": &"figure_slim", "label": "纤细", "mesh": "SiroinoSotai_Body",
				"shape": "All_Slim", "default": 0.0},
			{"id": &"figure_medium", "label": "微肉感", "mesh": "SiroinoSotai_Body",
				"shape": "All_M", "default": 0.0},
			{"id": &"figure_plump", "label": "丰满", "mesh": "SiroinoSotai_Body",
				"shape": "All_L", "default": 0.0},
		],
	},
	&"bust": {
		"label": "胸部",
		"sliders": [
			{"id": &"bust_flat", "label": "平胸", "mesh": "SiroinoSotai_Body",
				"shape": "Breasts_flat", "default": 0.0},
			{"id": &"bust_large", "label": "丰满", "mesh": "SiroinoSotai_Body",
				"shape": "Breasts_L", "default": 0.0},
			{"id": &"bust_xl", "label": "夸张", "mesh": "SiroinoSotai_Body",
				"shape": "Breasts_LL", "default": 0.0},
			{"id": &"bust_xxl", "label": "最大", "mesh": "SiroinoSotai_Body",
				"shape": "Breasts_LLL", "default": 0.0},
			{"id": &"bust_inner", "label": "内拢", "mesh": "SiroinoSotai_Body",
				"shape": "Breasts_In", "default": 0.0},
		],
	},
	&"face": {
		"label": "面部",
		"sliders": [
			{"id": &"face_blush", "label": "腮红", "mesh": "Akane_Head",
				"shape": "HEAD_Blushing", "default": 0.0},
		],
	},
}

## id -> {"mesh": MeshInstance3D, "index": int}; only sliders that resolved.
var _bindings: Dictionary = {}


## ArrayMesh exposes count/name accessors but **no** name→index lookup (there
## is no `find_blend_shape_by_name` in 4.7 — ClassDB-verified), so the index is
## a scan. Called a handful of times at setup, never per frame.
static func shape_index(array_mesh: ArrayMesh, shape_name: String) -> int:
	for i: int in range(array_mesh.get_blend_shape_count()):
		if array_mesh.get_blend_shape_name(i) == shape_name:
			return i
	return -1


## Resolve every catalog slider against the model. Unresolved entries are
## simply absent from `_bindings` — a mod model with a different mesh layout
## loses those sliders rather than erroring.
func setup(model: Node3D) -> void:
	_bindings.clear()
	if model == null:
		return
	for group_id: StringName in SLIDER_GROUPS:
		for slider: Dictionary in SLIDER_GROUPS[group_id]["sliders"]:
			var mesh_node := model.find_child(String(slider["mesh"]), true, false) as MeshInstance3D
			if mesh_node == null or mesh_node.mesh == null:
				continue
			# Blend-shape queries live on ArrayMesh, not the Mesh base — a cast
			# keeps the call typed instead of a Variant duck-type.
			var array_mesh := mesh_node.mesh as ArrayMesh
			if array_mesh == null:
				continue
			var index := shape_index(array_mesh, String(slider["shape"]))
			if index < 0:
				continue
			_bindings[slider["id"]] = {"mesh": mesh_node, "index": index}


## Whether the model carries at least one curated shape — the panel's signal
## for building the shape-key section.
static func has_curated_shapes(model: Node3D) -> bool:
	if model == null:
		return false
	for group_id: StringName in SLIDER_GROUPS:
		for slider: Dictionary in SLIDER_GROUPS[group_id]["sliders"]:
			var mesh_node := model.find_child(String(slider["mesh"]), true, false) as MeshInstance3D
			if mesh_node == null or mesh_node.mesh == null:
				continue
			var array_mesh := mesh_node.mesh as ArrayMesh
			if array_mesh == null:
				continue
			if shape_index(array_mesh, String(slider["shape"])) >= 0:
				return true
	return false


## The component riding on the model root, if the model has one.
static func find_on(model: Node3D) -> ModelBlendShapes:
	if model == null:
		return null
	return model.get_node_or_null("BlendShapes") as ModelBlendShapes


## Drive every catalog slider from a state dictionary. Absent ids read as the
## authored default, which gives `replace_state` whole-look semantics: a random
## or restored state that says nothing about shapes resets them.
static func apply_state(model: Node3D, values: Dictionary) -> void:
	var component := find_on(model)
	if component != null:
		component.apply_values(values)


func apply_values(values: Dictionary) -> void:
	for group_id: StringName in SLIDER_GROUPS:
		for slider: Dictionary in SLIDER_GROUPS[group_id]["sliders"]:
			var binding: Dictionary = _bindings.get(slider["id"], {})
			if binding.is_empty():
				continue
			var value := float(values.get(String(slider["id"]), slider["default"]))
			var mesh_instance: MeshInstance3D = binding["mesh"]
			mesh_instance.set_blend_shape_value(binding["index"], clampf(value, 0.0, 1.0))


## Defaults for every catalog slider, keyed the way the state stores them.
static func default_values() -> Dictionary:
	var values: Dictionary = {}
	for group_id: StringName in SLIDER_GROUPS:
		for slider: Dictionary in SLIDER_GROUPS[group_id]["sliders"]:
			values[String(slider["id"])] = float(slider["default"])
	return values


## Add every catalog default to a state that lacks it — the restore path needs
## this so a save written before the sliders existed still loads (its missing
## ids fall back to the authored body instead of being dropped).
static func merge_defaults(state: CharacterState) -> void:
	if state == null:
		return
	var defaults := default_values()
	for id: String in defaults:
		if not state.values.has(id):
			state.values[id] = defaults[id]


## Randomized values for `randomize` — biased toward *one* figure direction
## rather than noise, because `All_Slim` and `All_L` together fight over the
## same vertices and read as a mistake. Everything not rolled is filled with
## its default so the result is a complete, storable look.
static func randomized_values(rng: RandomNumberGenerator) -> Dictionary:
	var defaults := default_values()
	var values: Dictionary = {}
	for id: String in defaults:
		values[id] = defaults[id]
	var roll := rng.randf()
	if roll < 0.35:
		values["figure_slim"] = rng.randf_range(0.35, 1.0)
	elif roll < 0.7:
		values["figure_plump"] = rng.randf_range(0.2, 0.85)
		values["figure_medium"] = rng.randf_range(0.0, 0.4)
	else:
		values["figure_medium"] = rng.randf_range(0.1, 0.6)
		values["figure_slim"] = rng.randf_range(0.0, 0.25)
	var bust := rng.randf()
	if bust < 0.2:
		values["bust_flat"] = 1.0
	elif bust < 0.5:
		values["bust_large"] = rng.randf_range(0.3, 1.0)
	elif bust < 0.65:
		values["bust_xl"] = rng.randf_range(0.3, 1.0)
	if rng.randf() < 0.4:
		values["face_blush"] = rng.randf_range(0.2, 1.0)
	return values


## Write a randomized shape look straight into a state (the panel's random
## button overlays this on the outfit roll).
static func overlay_random(state: CharacterState, rng: RandomNumberGenerator = null) -> void:
	if state == null:
		return
	var random := rng if rng != null else RandomNumberGenerator.new()
	if rng == null:
		random.randomize()
	var values := randomized_values(random)
	for id: String in values:
		state.values[id] = values[id]
