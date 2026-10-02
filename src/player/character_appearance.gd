extends RefCounted
class_name CharacterAppearance
## Parametrised look of the Configura humanoid: which hair/outfit variant is
## visible, and what colour every material reads.
##
## The imported example model carries every variant mesh inside one `.blend`
## (`Hair_Fringe`, `Shirt_T Shirt`, ... — one node per variant, all visible on
## import), so a "swap" is visibility, not scene loading. Colour is a material
## albedo write. Both are driven from a standard Configura `CharacterState`
## built against a standard `CharacterConfig`, so a state saved by this file
## stays loadable by the plugin's own editor tooling (and vice versa).
##
## The plugin's runtime `CharacterStateApplier` cannot drive these options: its
## swap path loads *exported* mesh scenes and its colour path resolves full
## NodePaths that only exist after the creator workflow ran. This catalog is
## the runtime equivalent, resolving variants by node *name* inside whatever
## model root it is handed — the example model needs no export step.

## Mesh variant groups. `required` groups always show exactly one variant;
## optional groups prepend a "none" choice (value 0) that hides every variant.
## Node name = prefix + variant.
const SWAP_GROUPS: Dictionary = {
	&"hair_style": {
		"label": "发型", "prefix": "Hair_", "required": true,
		"variants": ["Fringe", "Layered", "Bob", "Bowl", "Bun", "Crew", "Curly",
			"Locs", "Ponytail", "Shag", "Spiked", "Spiked Forward", "Wavy"],
	},
	&"shirt_style": {
		"label": "上衣", "prefix": "Shirt_", "required": true,
		"variants": ["T Shirt", "Dress Shirt", "Long Sleeve", "Sweater", "Tank Top"],
	},
	&"pants_style": {
		"label": "下装", "prefix": "Pants_", "required": true,
		"variants": ["Long", "Shorts", "Long Skirt", "Short Skirt"],
	},
	&"shoes_style": {
		"label": "鞋子", "prefix": "Shoes_", "required": true,
		"variants": ["Boots", "Loafers"],
	},
	&"accessory_style": {
		"label": "配饰", "prefix": "Accessories_", "required": false,
		"variants": ["Round Glasses", "Square Glasses", "Hat", "Necklace",
			"Earings", "Cochlear Implant"],
	},
	&"facial_hair_style": {
		"label": "胡须", "prefix": "Facial Hair_", "required": false,
		"variants": ["Chevron Mustache", "Goatee", "Horseshoe Mustache", "Beard"],
	},
}

## Colourable material groups, by the meshes sharing each material.
const COLOR_GROUPS: Dictionary = {
	&"skin_color": {"label": "肤色", "prefix": "Base_",
		"meshes": ["Base_Body", "Base_Head", "Base_Ears"]},
	&"hair_color": {"label": "发色", "prefix": "Hair_", "meshes": []},
	&"shirt_color": {"label": "上衣色", "prefix": "Shirt_", "meshes": []},
	&"pants_color": {"label": "下装色", "prefix": "Pants_", "meshes": []},
	&"shoes_color": {"label": "鞋子色", "prefix": "Shoes_", "meshes": []},
	&"accessory_color": {"label": "配饰色", "prefix": "Accessories_", "meshes": []},
	&"eye_color": {"label": "瞳色", "prefix": "Base_", "meshes": ["Base_Eyes"]},
}

## The curated default. Chosen as one coherent outfit rather than plugin
## defaults: layered hair, warm skin, white tee / navy trousers / brown boots.
const DEFAULTS: Dictionary = {
	&"hair_style": "Layered",
	&"shirt_style": "T Shirt",
	&"pants_style": "Long",
	&"shoes_style": "Boots",
	&"accessory_style": "",
	&"facial_hair_style": "",
	&"skin_color": Color(0.79, 0.57, 0.42),
	&"hair_color": Color(0.23, 0.16, 0.12),
	&"shirt_color": Color(0.90, 0.88, 0.84),
	&"pants_color": Color(0.18, 0.25, 0.34),
	&"shoes_color": Color(0.35, 0.27, 0.20),
	&"accessory_color": Color(0.79, 0.65, 0.36),
	&"eye_color": Color.WHITE,
}

## Realistic skin tones for randomization — never HSV noise.
const SKIN_PALETTE: Array[Color] = [
	Color(0.95, 0.84, 0.76), Color(0.91, 0.73, 0.60), Color(0.79, 0.57, 0.42),
	Color(0.61, 0.42, 0.29), Color(0.43, 0.29, 0.19), Color(0.31, 0.20, 0.13),
]

## Hair colours for randomization.
const HAIR_PALETTE: Array[Color] = [
	Color(0.09, 0.07, 0.05), Color(0.23, 0.16, 0.12), Color(0.42, 0.29, 0.18),
	Color(0.73, 0.55, 0.31), Color(0.85, 0.70, 0.35), Color(0.66, 0.31, 0.16),
	Color(0.54, 0.54, 0.54), Color(0.91, 0.89, 0.85),
]

## Eye tints. White keeps the painted texture as authored.
const EYE_PALETTE: Array[Color] = [
	Color.WHITE, Color(0.35, 0.23, 0.12), Color(0.18, 0.31, 0.44), Color(0.25, 0.42, 0.23),
]

## Coordinated outfit swatches (shirt, pants, shoes, accessory) — randomization
## picks one whole row, so the result always reads as dressed on purpose.
const OUTFIT_SWATCHES: Array = [
	[Color(0.90, 0.88, 0.84), Color(0.18, 0.25, 0.34), Color(0.35, 0.27, 0.20), Color(0.79, 0.65, 0.36)],
	[Color(0.16, 0.16, 0.18), Color(0.45, 0.46, 0.48), Color(0.12, 0.12, 0.13), Color(0.60, 0.60, 0.62)],
	[Color(0.94, 0.93, 0.90), Color(0.28, 0.30, 0.32), Color(0.15, 0.15, 0.16), Color(0.30, 0.30, 0.32)],
	[Color(0.35, 0.40, 0.28), Color(0.55, 0.48, 0.35), Color(0.35, 0.27, 0.20), Color(0.42, 0.36, 0.26)],
	[Color(0.48, 0.16, 0.14), Color(0.12, 0.12, 0.13), Color(0.75, 0.73, 0.70), Color(0.79, 0.65, 0.36)],
	[Color(0.55, 0.68, 0.78), Color(0.82, 0.80, 0.76), Color(0.85, 0.83, 0.80), Color(0.30, 0.30, 0.32)],
	[Color(0.80, 0.55, 0.60), Color(0.18, 0.25, 0.34), Color(0.15, 0.15, 0.16), Color(0.79, 0.65, 0.36)],
	[Color(0.16, 0.24, 0.36), Color(0.72, 0.66, 0.55), Color(0.35, 0.27, 0.20), Color(0.55, 0.48, 0.35)],
]


## Build the standard option set the panel and the state are written against.
## One MeshSwapOption per variant group, one ColorOption per material group;
## `resource_name` is the stable id every layer routes by.
static func build_config() -> CharacterConfig:
	var config := CharacterConfig.new()
	for id: StringName in SWAP_GROUPS:
		var group: Dictionary = SWAP_GROUPS[id]
		var option := MeshSwapOption.new()
		option.resource_name = String(id)
		option.display_name = group["label"]
		option.group = group["label"]
		option.required = group["required"]
		option.default_choice = 0
		if not group["required"]:
			var none := MeshSwapChoice.new()
			none.label = "无"
			none.include = true
			option.choices.append(none)
		for variant: String in group["variants"]:
			var choice := MeshSwapChoice.new()
			choice.label = variant
			choice.include = true
			# The runtime applier resolves this by node name, not by full path.
			choice.mesh_path = NodePath(group["prefix"] + variant)
			option.choices.append(choice)
		config.options.append(option)
	for id: StringName in COLOR_GROUPS:
		var group: Dictionary = COLOR_GROUPS[id]
		var option := ColorOption.new()
		option.resource_name = String(id)
		option.display_name = group["label"]
		option.group = group["label"]
		option.shader_param = "albedo_color"
		option.surface_index = 0
		option.default_color = DEFAULTS.get(id, Color.WHITE)
		for mesh_name: String in _meshes_for(id, group):
			option.mesh_paths.append(NodePath(mesh_name))
		config.options.append(option)
	return config


## Mesh node names a colour group tints: the explicit list when one exists,
## otherwise every variant under the group's prefix.
static func _meshes_for(id: StringName, group: Dictionary) -> Array[String]:
	var names: Array[String] = []
	var explicit: Array = group["meshes"]
	if not explicit.is_empty():
		for name: String in explicit:
			names.append(name)
		return names
	for variant: String in SWAP_GROUPS[id.replace("_color", "_style")]["variants"]:
		names.append(group["prefix"] + variant)
	return names


## State carrying exactly the curated defaults.
static func default_state() -> CharacterState:
	var state := CharacterState.from_config(build_config())
	for id: StringName in DEFAULTS:
		if not state.values.has(String(id)):
			continue
		if String(id).ends_with("_style"):
			state.values[String(id)] = _choice_index(id, String(DEFAULTS[id]))
		else:
			state.values[String(id)] = DEFAULTS[id]
	state.last_modified = Time.get_unix_time_from_system()
	return state


## Translate a variant name ("Layered") into the state value (choice index)
## the swap option stores. Empty name → the "none" slot of an optional group.
static func _choice_index(style_id: StringName, variant: String) -> int:
	var group: Dictionary = SWAP_GROUPS[style_id]
	if not group["required"] and variant.is_empty():
		return 0
	var offset: int = 0 if group["required"] else 1
	var index: int = group["variants"].find(variant)
	return index + offset if index >= 0 else (offset if group["required"] else 0)


## A coordinated random look: one whole outfit row, a real skin tone, a hair
## colour, and accessories only sometimes. Optional groups default to "none"
## with a chance of wearing something.
static func randomized_state(rng: RandomNumberGenerator = null) -> CharacterState:
	var state := default_state()
	var random := rng if rng != null else RandomNumberGenerator.new()
	if rng == null:
		random.randomize()
	for id: StringName in SWAP_GROUPS:
		var group: Dictionary = SWAP_GROUPS[id]
		var offset: int = 0 if group["required"] else 1
		var roll: float = random.randf()
		var wears: bool = group["required"] or roll < 0.25
		if not wears:
			state.values[String(id)] = 0
			continue
		state.values[String(id)] = offset + random.randi_range(0, group["variants"].size() - 1)
	state.values["skin_color"] = SKIN_PALETTE[random.randi_range(0, SKIN_PALETTE.size() - 1)]
	state.values["hair_color"] = HAIR_PALETTE[random.randi_range(0, HAIR_PALETTE.size() - 1)]
	state.values["eye_color"] = EYE_PALETTE[random.randi_range(0, EYE_PALETTE.size() - 1)]
	var outfit: Array = OUTFIT_SWATCHES[random.randi_range(0, OUTFIT_SWATCHES.size() - 1)]
	state.values["shirt_color"] = outfit[0]
	state.values["pants_color"] = outfit[1]
	state.values["shoes_color"] = outfit[2]
	state.values["accessory_color"] = outfit[3]
	state.last_modified = Time.get_unix_time_from_system()
	return state


## Swatch colours the panel offers for a colour option.
static func palette(option_id: String) -> Array[Color]:
	match StringName(option_id):
		&"skin_color":
			return SKIN_PALETTE
		&"hair_color":
			return HAIR_PALETTE
		&"eye_color":
			return EYE_PALETTE
	var colors: Array[Color] = []
	for outfit: Array in OUTFIT_SWATCHES:
		var index: int = {
			&"shirt_color": 0, &"pants_color": 1,
			&"shoes_color": 2, &"accessory_color": 3,
		}.get(StringName(option_id), 0)
		colors.append(outfit[index])
	return colors


## Apply a whole state to a model root: hide every non-selected variant, tint
## the colour groups. Missing meshes are skipped silently — a model without a
## variant is a valid look, and the capsule fallback needs nothing here.
static func apply(state: CharacterState, model_root: Node) -> void:
	if model_root == null:
		return
	var meshes := _mesh_index(model_root)
	var config := build_config()
	for option: OptionDefinition in config.options:
		var value: Variant = state.values.get(option.resource_name)
		if value == null:
			continue
		if option is MeshSwapOption:
			_apply_swap(option as MeshSwapOption, value, meshes)
		elif option is ColorOption:
			_apply_color(option as ColorOption, value, meshes)


## Name → MeshInstance3D lookup built once per pass. Variant nodes are found by
## bare name anywhere under the root, so the exact skeleton nesting of the
## imported `.blend` does not matter here.
static func _mesh_index(model_root: Node) -> Dictionary:
	var index: Dictionary = {}
	for mesh: Node in model_root.find_children("*", "MeshInstance3D", true, false):
		if not index.has(mesh.name):
			index[mesh.name] = mesh
	return index


static func _apply_swap(option: MeshSwapOption, value: Variant, meshes: Dictionary) -> void:
	for choice_index: int in option.choices.size():
		var choice := option.choices[choice_index]
		if choice.mesh_path.is_empty():
			continue
		var mesh: Node3D = meshes.get(String(choice.mesh_path))
		if mesh == null:
			continue
		mesh.visible = choice_index == int(value)


static func _apply_color(option: ColorOption, value: Variant, meshes: Dictionary) -> void:
	var color: Color = value if value is Color else Color.WHITE
	for path: NodePath in option.mesh_paths:
		var mesh: MeshInstance3D = meshes.get(String(path))
		if mesh == null or mesh.mesh == null:
			continue
		for surface: int in mesh.mesh.get_surface_count():
			var material := mesh.get_active_material(surface)
			if material == null:
				material = StandardMaterial3D.new()
			else:
				material = material.duplicate()
			if material is StandardMaterial3D:
				(material as StandardMaterial3D).albedo_color = color
				mesh.set_surface_override_material(surface, material)
