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

## Body-proportion groups, driven by bone **rest** edits rather than poses:
## the idle animation rewrites poses every frame, but the skin binds through
## rests, so a rest edit keeps shaping the mesh through playback instead of
## being stomped by the next animation frame. Rest scaling also cascades to
## child bones, which is what makes a spine edit read as height.
##
## Values live in [-1, 1]; `strength` is the scale delta at ±1. Ops accumulate
## across groups on top of the cached original rests, so overlapping targets
## (height and leg length both scale the thigh) compose instead of fighting.
##
## ## The bones are named by **role**, not by rig
##
## This table used to list the imported example's Rigify bones outright
## (`spine`, `spine.001`, `thigh.L`, `upper_arm.L`) and rely on "missing bones are
## skipped silently". On the shipped figure that was not a graceful degradation,
## it was a total no-op: measured against `base_female`, **0 of 21** targets
## existed. Every proportion slider — height, shoulder width, arm length, leg
## length, build — did nothing at all, silently.
##
## The targets are now roles, and `resolve_role` maps a role onto whatever the
## loaded rig actually calls that bone. The names below are the **VRM 1.0**
## convention because that is what this game's figure ships as; a Rigify or
## Unreal rig is mapped through the same table. This is the first user of the
## role vocabulary that `SkeletonContract` will formalise — the two share it so
## there is one mapping, not two.
const DEFORM_GROUPS: Dictionary = {
	# Height scales the whole spine column and both thighs, so the figure grows
	# from the hips up rather than stretching one segment. The role list is
	# deliberately redundant: a rig may carry a two-bone spine, a seven-bone
	# one, or a single `Spine`, and every bone that exists is scaled, so the
	# slider reads the same on all three. Scaling a bone's rest cascades to its
	# children, which is why the legs are listed here as well — a taller figure
	# needs the legs to carry the extra height or the hips end up inside the
	# floor.
	&"body_height": {
		"label": "身高", "strength": 0.13,
		"scale_y": ["Spine", "Chest", "Spine2", "Neck",
			"LeftUpperLeg", "RightUpperLeg", "LeftLowerLeg", "RightLowerLeg"],
	},
	&"shoulder_width": {
		# The shoulders, not an upper-chest bone: VRM 1.0 has no `UpperChest`, and
		# the previous target (`spine.003`) existed on neither convention this
		# game loads. Widening the shoulder joints moves the arms outward, which
		# is what the slider is for.
		"label": "肩宽", "strength": 0.35,
		"scale_x": ["ShoulderL", "ShoulderR"],
	},
	&"arm_length": {
		"label": "臂长", "strength": 0.16,
		"scale_y": ["LeftUpperArm", "RightUpperArm"],
	},
	&"leg_length": {
		"label": "腿长", "strength": 0.12,
		"scale_y": ["LeftUpperLeg", "RightUpperLeg", "LeftLowerLeg", "RightLowerLeg"],
	},
	&"body_build": {
		"label": "体型", "strength": 0.28,
		"scale_xz": ["Spine", "Chest"],
	},
}

## Role → bone name, per rig convention. A role that a rig does not have is
## simply absent, and the caller skips it — which is the graceful degradation
## the old table was reaching for and never got.
##
## Only the conventions this project can actually load are listed. `vrm` is the
## shipped figure; `rigify` is what the earlier table assumed, kept because the
## Configura example in `addons/` still uses it, so a figure swapped in from
## there keeps working.
const ROLE_BONES: Dictionary = {
	&"vrm": {
		# A VRM's leg and arm bones are named without the side suffix split, and
		# its spine runs Spine → Chest → Neck. The Rigify fallbacks are here as
		# well because a name is a name: a rig that happens to carry both
		# conventions resolves through whichever table is selected, and a single
		# role must not come back empty just because the figure spells it
		# differently.
		"Spine": [&"Spine", &"spine"],
		"Chest": [&"Chest", &"chest", &"Spine2", &"spine.003", &"spine.004"],
		"UpperChest": [&"UpperChest", &"upper_chest", &"Spine2", &"spine.004", &"spine.006"],
		"Neck": [&"Neck", &"neck"],
		"LeftUpperLeg": [&"LeftUpperLeg", &"thigh.L", &"left_thigh"],
		"RightUpperLeg": [&"RightUpperLeg", &"thigh.R", &"right_thigh"],
		"LeftLowerLeg": [&"LeftLowerLeg", &"shin.L", &"left_calf"],
		"RightLowerLeg": [&"RightLowerLeg", &"shin.R", &"right_calf"],
		"LeftUpperArm": [&"LeftUpperArm", &"upper_arm.L"],
		"RightUpperArm": [&"RightUpperArm", &"upper_arm.R"],
		"ShoulderL": [&"LeftShoulder", &"shoulder.L"],
		"ShoulderR": [&"RightShoulder", &"shoulder.R"],
		"LeftFoot": [&"LeftFoot", &"foot.L", &"LeftToeBase", &"heel.02.L"],
		"RightFoot": [&"RightFoot", &"foot.R", &"RightToeBase", &"heel.02.R"],
	},
	&"rigify": {
		"Spine": [&"spine", &"spine.001", &"spine.002"],
		"Chest": [&"spine.003", &"spine.004", &"chest"],
		"UpperChest": [&"spine.004", &"spine.005", &"spine.006"],
		"Neck": [&"neck"],
		"LeftUpperLeg": [&"thigh.L"],
		"RightUpperLeg": [&"thigh.R"],
		"LeftLowerLeg": [&"shin.L"],
		"RightLowerLeg": [&"shin.R"],
		"LeftUpperArm": [&"upper_arm.L"],
		"RightUpperArm": [&"upper_arm.R"],
		"ShoulderL": [&"shoulder.L"],
		"ShoulderR": [&"shoulder.R"],
		"LeftFoot": [&"foot.L", &"heel.02.L"],
		"RightFoot": [&"foot.R", &"heel.02.R"],
	},
}

## Which convention a skeleton's bone names follow, decided by what it actually
## has rather than by a setting: a rig with `Hips` and `LeftFoot` is VRM, one
## with `spine` and `foot.L` is Rigify. Anything unrecognised falls back to VRM,
## which is right for this project's figure and harmless elsewhere because every
## name then simply fails to resolve and is skipped.
static func detect_rig_convention(skeleton: Skeleton3D) -> StringName:
	if skeleton == null:
		return &"vrm"
	if skeleton.find_bone(&"Hips") >= 0 or skeleton.find_bone(&"LeftFoot") >= 0:
		return &"vrm"
	if skeleton.find_bone(&"spine") >= 0 or skeleton.find_bone(&"foot.L") >= 0:
		return &"rigify"
	return &"vrm"


## Every bone name for `role` on this skeleton, in preference order.
##
## A role can be a *segment* rather than a single bone: a height edit has to
## scale the whole spine column, and returning only the first match would scale
## one vertebra and leave the rest at the authored length. So this returns all
## the names the rig actually has for the role, and the caller walks them.
static func resolve_all_roles(skeleton: Skeleton3D, role: String, convention: StringName) -> Array[String]:
	var found: Array[String] = []
	var table: Dictionary = ROLE_BONES.get(convention, ROLE_BONES[&"vrm"])
	var candidates: Array = table.get(role, [])
	for candidate: StringName in candidates:
		if skeleton.find_bone(candidate) >= 0:
			found.append(String(candidate))
	return found


## The single bone for `role`, or an empty string when the rig has none. Used
## where exactly one bone is meant — the foot anchor, the shoulder a slider
## widens.
static func resolve_role(skeleton: Skeleton3D, role: String, convention: StringName) -> String:
	var table: Dictionary = ROLE_BONES.get(convention, ROLE_BONES[&"vrm"])
	var candidates: Array = table.get(role, [])
	for candidate: StringName in candidates:
		if skeleton.find_bone(candidate) >= 0:
			return String(candidate)
	return ""

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
	&"body_height": 0.0,
	&"shoulder_width": 0.0,
	&"arm_length": 0.0,
	&"leg_length": 0.0,
	&"body_build": 0.0,
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
	for id: StringName in DEFORM_GROUPS:
		var option := DeformOption.new()
		option.resource_name = String(id)
		option.display_name = DEFORM_GROUPS[id]["label"]
		option.group = "体形"
		option.deform_type = DeformOption.DeformType.BIDIRECTIONAL
		option.min_value = -1.0
		option.max_value = 1.0
		option.default_value = float(DEFAULTS.get(id, 0.0))
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
	# Proportions stay near the authored body: a random look may be a little
	# taller, broader or heavier, never a caricature.
	for id: StringName in DEFORM_GROUPS:
		state.values[String(id)] = random.randf_range(-0.45, 0.45)
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
## the colour groups, and drive body proportions through the skeleton's rests.
## Missing meshes or bones are skipped silently — a model without a variant is
## a valid look, and the capsule fallback needs nothing here.
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
		# Deform groups are resolved against the skeleton(s) below, not per
		# option: their edits accumulate across groups, so they are applied in
		# one reset-and-rebuild pass per skeleton.
	for skeleton: Node in model_root.find_children("*", "Skeleton3D", true, false):
		_apply_deforms(state, skeleton as Skeleton3D)


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


## Drive every body-proportion group into one skeleton, in a single
## reset-and-rebuild pass so repeated applies never drift.
##
## The authored rests (and the skeleton's base Y) are cached on the skeleton as
## meta the first time this runs; every pass restores them first, then layers
## each group's scale delta on top. Because a lengthened leg pushes the foot
## below the floor line, the pass ends by re-anchoring the skeleton so the
## lowest foot bone sits exactly where it started — height changes read on the
## body, not as sinking into the ground.
static func _apply_deforms(state: CharacterState, skeleton: Skeleton3D) -> void:
	if skeleton == null or skeleton.get_bone_count() == 0:
		return
	var baseline: Dictionary = skeleton.get_meta(&"appearance_rest_baseline", {})
	if baseline.is_empty():
		baseline = {}
		for bone: int in skeleton.get_bone_count():
			baseline[skeleton.get_bone_name(bone)] = skeleton.get_bone_rest(bone)
		skeleton.set_meta(&"appearance_rest_baseline", baseline)
		skeleton.set_meta(&"appearance_base_y", skeleton.position.y)
	var base_y: float = float(skeleton.get_meta(&"appearance_base_y", 0.0))
	# Which naming world this skeleton speaks, decided from the bones it
	# actually has. Cached on the meta alongside the rest baseline so every
	# apply pass agrees, even if the rig is rebuilt under us.
	var convention: StringName = StringName(
		skeleton.get_meta(&"appearance_rig_convention", ""))
	if convention.is_empty():
		convention = detect_rig_convention(skeleton)
		skeleton.set_meta(&"appearance_rig_convention", String(convention))

	# Restore, then accumulate: a group's edit is written against the authored
	# rest, so height + leg length on the same thigh compose predictably.
	var edited: Dictionary = {}
	for bone_name: String in baseline:
		var index := skeleton.find_bone(bone_name)
		if index >= 0:
			skeleton.set_bone_rest(index, baseline[bone_name])
			edited[bone_name] = index
	skeleton.position.y = base_y

	for id: StringName in DEFORM_GROUPS:
		var value := clampf(float(state.values.get(String(id), 0.0)), -1.0, 1.0)
		if is_zero_approx(value):
			continue
		var group: Dictionary = DEFORM_GROUPS[id]
		var factor := 1.0 + value * float(group["strength"])
		for op: String in ["scale_y", "scale_x", "scale_xz"]:
			for role: String in group.get(op, []):
				# The group names a *role*; the rig names bones. Resolving here is
				# what makes a slider work on a figure whose naming differs from
				# the example this table was written against. All the bones the
				# rig has for the role are edited, because a role can be a whole
				# segment (a spine) rather than one bone.
				for bone_name: String in resolve_all_roles(skeleton, role, convention):
					var index: int = edited.get(bone_name, -1)
					if index < 0:
						continue
					var rest: Transform3D = skeleton.get_bone_rest(index)
					var scale: Vector3 = rest.basis.get_scale()
					match op:
						"scale_y":
							scale.y *= factor
						"scale_x":
							scale.x *= factor
						"scale_xz":
							scale.x *= factor
							scale.z *= factor
					rest.basis = Basis(rest.basis.get_rotation_quaternion()).scaled(scale)
					skeleton.set_bone_rest(index, rest)

	# Re-anchor: the lowest foot-bone rest must return to its authored height,
	# whatever the combination of length edits did to the chain above it.
	#
	# The anchor used to be `heel.02.L` with a `foot.L` fallback — both Rigify
	# names, neither of which the shipped VRM figure has, so the whole
	# correction returned early and never ran. Resolving the role instead makes
	# it work on whichever rig is loaded, and the *lowest* foot bone is the
	# right anchor: the shorter leg would otherwise hang below the floor line.
	var anchor := -1
	var anchor_y := INF
	for role: String in ["LeftFoot", "RightFoot"]:
		var bone_name: String = resolve_role(skeleton, role, convention)
		if bone_name.is_empty():
			continue
		var index: int = skeleton.find_bone(StringName(bone_name))
		if index < 0:
			continue
		var height: float = _global_rest_y(skeleton, index, {})
		if height < anchor_y:
			anchor_y = height
			anchor = index
	if anchor < 0:
		return
	var authored_anchor_y := base_y + _global_rest_y(skeleton, anchor, baseline)
	skeleton.position.y = authored_anchor_y - anchor_y


## World-rest height of a bone: its global rest origin's Y relative to the
## skeleton. `overrides` lets the caller measure against the authored rests
## instead of the ones currently set.
static func _global_rest_y(skeleton: Skeleton3D, bone: int, overrides: Dictionary) -> float:
	var rest: Transform3D = skeleton.get_bone_rest(bone)
	if not overrides.is_empty():
		rest = overrides.get(skeleton.get_bone_name(bone), rest)
	# The child's origin lives in its parent's scaled space, so every ancestor
	# with a Y rest scale stretches the distance to this bone.
	var y: float = rest.origin.y
	var parent := skeleton.get_bone_parent(bone)
	while parent >= 0:
		var parent_rest: Transform3D = skeleton.get_bone_rest(parent)
		if not overrides.is_empty():
			parent_rest = overrides.get(skeleton.get_bone_name(parent), parent_rest)
		y = parent_rest.origin.y + y * parent_rest.basis.get_scale().y
		parent = skeleton.get_bone_parent(parent)
	return y
