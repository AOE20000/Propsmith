extends RefCounted
class_name DemoLook
## The demo's visual baseline: one tuned `Environment` plus the sun that lights
## it, assembled in code like every other scene in this project.
##
## Why a module and not a base class. A map source owns its own mood — a lawn and
## a dense city genuinely want different colours — but "warm horizon, filmic
## exposure, gentle bloom, fog that fades the far wall away" is a house style
## that should be tuned once and referred to from everywhere. A map source opts
## in by calling `apply()` with the preset that fits; nothing is inherited and no
## map source gains a dependency it did not ask for.
##
## Presets are plain dictionaries on purpose. The day/dusk switch, a photo-mode
## filter, or a mod that wants its own weather all read the same table — and can
## push their own numbers through `apply_to()` without editing this file.
##
## Every preset answers the same keys, so adding one is a data edit rather than a
## code edit; `apply_to()` reads the merged dictionary, never the preset name.

const DEFAULT_PRESET: StringName = &"day"

## Node metadata key holding the active preset on the `WorldEnvironment`.
const PRESET_META: StringName = &"demo_look_preset"

## How many glow mip levels `Environment` exposes. `set_glow_level` is 0-based
## while the inspector labels the same seven levels 1..7, so the loop bound and
## the preset table have to agree on which way round that is — getting it wrong
## is an out-of-bounds `Index p_level = 7` at runtime, not a clamped value.
const GLOW_LEVELS: int = 7


## Build the environment and its sun under `world_root` and tune them to
## `preset_name`. Returns `{environment, sun, preset}` — the handles are handed
## back rather than looked up later so a caller that wants to switch presets at
## runtime (day → dusk) keeps a direct reference instead of walking the tree.
##
## `overrides` is merged over the preset, so a caller can nudge one value
## ("warmer fog tonight") without cloning the whole table.
static func apply(world_root: Node3D, preset_name: StringName = DEFAULT_PRESET, overrides: Dictionary = {}) -> Dictionary:
	var world_environment := WorldEnvironment.new()
	world_environment.name = "Environment"
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	world_environment.environment = environment

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"

	# Siblings under the world, not parent/child: `WorldEnvironment` is a plain
	# `Node` with no transform, and pretending otherwise would only confuse the
	# next reader of the scene tree.
	world_root.add_child(world_environment)
	world_root.add_child(sun)

	var resolved: StringName = preset_name if has_preset(preset_name) else DEFAULT_PRESET
	# The active preset is recorded on the node, not just used and forgotten: a
	# render style retunes the environment later, and "later" is a different
	# module that must be able to ask which look it is deviating from. Carrying it
	# in the world means the answer travels with the world across a map reload.
	world_environment.set_meta(PRESET_META, String(resolved))
	apply_to(environment, sun, resolved, overrides)
	return {"environment": world_environment, "sun": sun, "preset": resolved}


## The preset a `WorldEnvironment` was built with, or `DEFAULT_PRESET` when it was
## built by something other than `apply()` — a mod map source, a hand-made scene.
## Degrading to the default beats refusing to restyle.
static func preset_of(world_environment: WorldEnvironment) -> StringName:
	if world_environment == null:
		return DEFAULT_PRESET
	return StringName(String(world_environment.get_meta(PRESET_META, String(DEFAULT_PRESET))))


## Retune an existing environment/sun pair. This is the whole implementation of
## `apply`, exposed because a runtime preset switch is the same operation on nodes
## that already exist — building a second WorldEnvironment to change the time of
## day would leave two skies fighting over the frame.
##
## Returns false (changing nothing) when the preset is unknown, so a typo in a
## mod's config degrades to "the look stayed as it was" rather than a crash.
static func apply_to(environment: Environment, sun: DirectionalLight3D, preset_name: StringName, overrides: Dictionary = {}) -> bool:
	if environment == null or sun == null:
		return false
	var data: Dictionary = _merged(preset_name, overrides)
	if data.is_empty():
		push_warning("DemoLook.apply_to: unknown preset '%s'" % preset_name)
		return false
	_apply_sky(environment, data)
	_apply_environment(environment, data)
	_apply_sun(sun, data)
	return true


## Switch the preset a live world is wearing.
##
## The metadata write is the part that matters, and the reason this exists instead
## of callers reaching for `apply_to`: `preset_of()` is how a render style asks
## *what it is deviating from*. A preset changed without updating the meta would
## leave the next style deriving its overrides from a look the world no longer has
## — dusk's fog on day's colours, and nothing to point at.
static func set_preset(world_environment: WorldEnvironment, sun: DirectionalLight3D, preset_name: StringName) -> bool:
	if world_environment == null or world_environment.environment == null or sun == null:
		return false
	if not has_preset(preset_name):
		push_warning("DemoLook.set_preset: unknown preset '%s'" % preset_name)
		return false
	world_environment.set_meta(PRESET_META, String(preset_name))
	apply_to(world_environment.environment, sun, preset_name)
	return true


## Preset names in table order, for menus and for the boot report.
static func preset_names() -> PackedStringArray:
	return PackedStringArray(table().keys())


static func has_preset(preset_name: StringName) -> bool:
	return table().has(preset_name)


## One preset's full parameter set, or `{}` when the name is unknown. Returns a
## copy: a caller editing the result must not be able to poison the table for the
## next map, and presets are read a handful of times per session, so the copy is
## free in any sense that matters.
static func preset(preset_name: StringName) -> Dictionary:
	var all: Dictionary = table()
	if not all.has(preset_name):
		return {}
	return (all[preset_name] as Dictionary).duplicate(true)


## Human-readable label for a preset, falling back to the raw name.
static func label(preset_name: StringName) -> String:
	var data: Dictionary = preset(preset_name)
	return String(data.get("label", String(preset_name)))


static func describe(preset_name: StringName) -> String:
	var data: Dictionary = preset(preset_name)
	if data.is_empty():
		return "unknown preset '%s'" % preset_name
	return "%s (%s) sun %.2f @ %s, exposure %.2f, fog %.4f%s" % [
		preset_name,
		String(data["label"]),
		float(data["sun_energy"]),
		str(data["sun_angle"]),
		float(data["exposure"]),
		float(data["fog_density"]),
		", volumetric" if bool(data["volumetric_fog_enabled"]) else "",
	]


## The preset table. Built on demand rather than held as a `const` so the
## `Color`/`Vector3` constructors stay ordinary expressions — a constant
## dictionary of nested constructors is exactly the kind of thing that parses
## differently across engine versions, and this table is read a handful of times
## per session.
static func table() -> Dictionary:
	return {
		&"day": {
			"label": "晴日",
			"sky_top": Color(0.33, 0.52, 0.80),
			"sky_horizon": Color(0.86, 0.85, 0.79),
			"sky_curve": 0.18,
			"sky_energy": 1.0,
			"ground_bottom": Color(0.34, 0.32, 0.28),
			"ground_horizon": Color(0.80, 0.79, 0.73),
			"ground_curve": 0.08,
			"ground_energy": 0.9,
			"ambient_sky_contribution": 1.0,
			"ambient_energy": 0.5,
			"reflected_light_source": &"bg",
			"sun_angle": Vector3(-42.0, -38.0, 0.0),
			"sun_color": Color(1.0, 0.95, 0.86),
			"sun_energy": 1.4,
			"sun_angular_distance": 0.5,
			"sun_in_sky": true,
			"shadow_enabled": true,
			"shadow_bias": 0.06,
			"shadow_normal_bias": 1.5,
			"shadow_max_distance": 130.0,
			"tonemap": &"aces",
			"exposure": 0.98,
			"white": 1.0,
			"saturation": 1.10,
			"contrast": 1.08,
			"brightness": 1.0,
			"glow_enabled": true,
			"glow_intensity": 0.30,
			"glow_bloom": 0.10,
			"glow_hdr_threshold": 1.0,
			"glow_blend_mode": Environment.GLOW_BLEND_MODE_SCREEN,
			# Seven entries, smallest blur first — `glow_levels/1..7` in the
			# inspector. Weighted toward the middle-large levels so the glow
			# reads as haze rather than as a halo around every bright pixel.
			"glow_levels": [0.0, 0.1, 0.35, 0.8, 1.0, 0.65, 0.35],
			"fog_enabled": true,
			"fog_color": Color(0.80, 0.84, 0.88),
			"fog_energy": 1.0,
			"fog_density": 0.0020,
			"fog_aerial_perspective": 0.35,
			"fog_sky_affect": 0.0,
			"fog_sun_scatter": 0.15,
			"fog_height": 0.0,
			"fog_height_density": 0.0,
			"ssao_enabled": true,
			"ssao_radius": 1.4,
			"ssao_intensity": 2.2,
			"ssao_power": 1.5,
			"ssao_light_affect": 0.15,
			"ssr_enabled": true,
			"ssr_max_steps": 32,
			"ssr_fade_in": 0.2,
			"ssr_fade_out": 8.0,
			"volumetric_fog_enabled": false,
			"volumetric_fog_density": 0.01,
			"volumetric_fog_albedo": Color(0.9, 0.9, 0.92),
			"volumetric_fog_anisotropy": 0.2,
		},
		&"dusk": {
			"label": "黄昏",
			"sky_top": Color(0.19, 0.25, 0.47),
			"sky_horizon": Color(0.95, 0.63, 0.42),
			"sky_curve": 0.12,
			"sky_energy": 1.0,
			"ground_bottom": Color(0.20, 0.17, 0.19),
			"ground_horizon": Color(0.70, 0.48, 0.38),
			"ground_curve": 0.10,
			"ground_energy": 0.7,
			"ambient_sky_contribution": 1.0,
			"ambient_energy": 0.45,
			"reflected_light_source": &"bg",
			"sun_angle": Vector3(-9.0, -56.0, 0.0),
			"sun_color": Color(1.0, 0.70, 0.45),
			"sun_energy": 1.55,
			"sun_angular_distance": 0.9,
			"sun_in_sky": true,
			"shadow_enabled": true,
			"shadow_bias": 0.06,
			"shadow_normal_bias": 1.5,
			"shadow_max_distance": 130.0,
			"tonemap": &"aces",
			"exposure": 1.15,
			"white": 1.0,
			"saturation": 1.10,
			"contrast": 1.05,
			"brightness": 1.0,
			"glow_enabled": true,
			"glow_intensity": 0.55,
			"glow_bloom": 0.22,
			"glow_hdr_threshold": 0.95,
			"glow_blend_mode": Environment.GLOW_BLEND_MODE_SCREEN,
			"glow_levels": [0.0, 0.15, 0.45, 0.9, 1.0, 0.7, 0.45],
			"fog_enabled": true,
			"fog_color": Color(0.88, 0.63, 0.48),
			"fog_energy": 1.1,
			"fog_density": 0.0032,
			"fog_aerial_perspective": 0.4,
			"fog_sky_affect": 0.0,
			"fog_sun_scatter": 0.3,
			"fog_height": 0.0,
			"fog_height_density": 0.0,
			"ssao_enabled": true,
			"ssao_radius": 1.4,
			"ssao_intensity": 2.4,
			"ssao_power": 1.5,
			"ssao_light_affect": 0.2,
			"ssr_enabled": true,
			"ssr_max_steps": 32,
			"ssr_fade_in": 0.2,
			"ssr_fade_out": 8.0,
			"volumetric_fog_enabled": false,
			"volumetric_fog_density": 0.02,
			"volumetric_fog_albedo": Color(0.95, 0.75, 0.6),
			"volumetric_fog_anisotropy": 0.3,
		},
		# The city keeps its own temperature — cooler and greyer than the lawn —
		# but gains the shared exposure, glow and ambient occlusion. Its heavier
		# geometry budget is why screen-space reflections stay off here.
		&"city": {
			"label": "城市白昼",
			"sky_top": Color(0.36, 0.55, 0.78),
			"sky_horizon": Color(0.71, 0.77, 0.83),
			"sky_curve": 0.15,
			"sky_energy": 1.0,
			"ground_bottom": Color(0.28, 0.28, 0.30),
			"ground_horizon": Color(0.71, 0.77, 0.83),
			"ground_curve": 0.02,
			"ground_energy": 1.0,
			"ambient_sky_contribution": 1.0,
			"ambient_energy": 0.7,
			"reflected_light_source": &"bg",
			"sun_angle": Vector3(-52.0, -28.0, 0.0),
			"sun_color": Color(1.0, 0.97, 0.92),
			"sun_energy": 1.15,
			"sun_angular_distance": 0.4,
			"sun_in_sky": true,
			"shadow_enabled": true,
			"shadow_bias": 0.08,
			"shadow_normal_bias": 2.0,
			"shadow_max_distance": 220.0,
			"tonemap": &"aces",
			"exposure": 1.0,
			"white": 1.0,
			"saturation": 1.0,
			"contrast": 1.0,
			"brightness": 1.0,
			"glow_enabled": true,
			"glow_intensity": 0.22,
			"glow_bloom": 0.0,
			"glow_hdr_threshold": 1.05,
			"glow_blend_mode": Environment.GLOW_BLEND_MODE_SOFTLIGHT,
			"glow_levels": [0.0, 0.0, 0.15, 0.5, 1.0, 0.4, 0.15],
			"fog_enabled": true,
			"fog_color": Color(0.74, 0.79, 0.84),
			"fog_energy": 1.0,
			"fog_density": 0.0012,
			"fog_aerial_perspective": 0.25,
			"fog_sky_affect": 0.0,
			"fog_sun_scatter": 0.1,
			"fog_height": 0.0,
			"fog_height_density": 0.0,
			"ssao_enabled": true,
			"ssao_radius": 2.0,
			"ssao_intensity": 1.8,
			"ssao_power": 1.5,
			"ssao_light_affect": 0.1,
			"ssr_enabled": false,
			"ssr_max_steps": 32,
			"ssr_fade_in": 0.2,
			"ssr_fade_out": 8.0,
			"volumetric_fog_enabled": false,
			"volumetric_fog_density": 0.01,
			"volumetric_fog_albedo": Color(0.9, 0.9, 0.92),
			"volumetric_fog_anisotropy": 0.2,
		},
	}


## Preset data with `overrides` folded in. Missing keys fall back to the default
## preset's value rather than to an engine default, so an override of a value a
## preset forgot to define cannot silently split the look in two.
static func _merged(preset_name: StringName, overrides: Dictionary) -> Dictionary:
	var data: Dictionary = preset(preset_name)
	if data.is_empty():
		return {}
	if overrides.is_empty():
		return data
	var defaults: Dictionary = preset(DEFAULT_PRESET)
	for key: Variant in overrides:
		if defaults.has(key):
			data[key] = overrides[key]
	return data


static func _apply_sky(environment: Environment, data: Dictionary) -> void:
	var sky: Sky = environment.sky
	if sky == null:
		sky = Sky.new()
		environment.sky = sky
	var material: ProceduralSkyMaterial = sky.sky_material as ProceduralSkyMaterial
	if material == null:
		material = ProceduralSkyMaterial.new()
		sky.sky_material = material
	material.sky_top_color = data["sky_top"]
	material.sky_horizon_color = data["sky_horizon"]
	material.sky_curve = data["sky_curve"]
	material.sky_energy_multiplier = data["sky_energy"]
	material.ground_bottom_color = data["ground_bottom"]
	material.ground_horizon_color = data["ground_horizon"]
	material.ground_curve = data["ground_curve"]
	material.ground_energy_multiplier = data["ground_energy"]


static func _apply_environment(environment: Environment, data: Dictionary) -> void:
	environment.background_mode = Environment.BG_SKY
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_sky_contribution = data["ambient_sky_contribution"]
	environment.ambient_light_energy = data["ambient_energy"]
	# Where specular light comes from. `bg` is the engine default; `disabled` is
	# what a flat, cel-shaded look wants — ambient specular off a gradient sky is a
	# broad soft highlight that varies across a flat surface, which reads as a
	# smudge on a wall rather than as light.
	environment.reflected_light_source = _reflection_source_for(StringName(data["reflected_light_source"]))

	# One exposure curve for the whole game: the presets differ in colour and
	# light, never in how the frame is developed, which is what keeps a day shot
	# and a dusk shot readable as the same world.
	environment.tonemap_mode = _tonemap_for(StringName(data["tonemap"]))
	environment.tonemap_exposure = data["exposure"]
	environment.tonemap_white = data["white"]

	environment.adjustment_enabled = true
	environment.adjustment_brightness = data["brightness"]
	environment.adjustment_contrast = data["contrast"]
	environment.adjustment_saturation = data["saturation"]

	environment.glow_enabled = data["glow_enabled"]
	environment.glow_intensity = data["glow_intensity"]
	environment.glow_bloom = data["glow_bloom"]
	environment.glow_hdr_threshold = data["glow_hdr_threshold"]
	environment.glow_blend_mode = data["glow_blend_mode"]
	var levels: Array = data["glow_levels"]
	for index: int in mini(levels.size(), GLOW_LEVELS):
		environment.set_glow_level(index, float(levels[index]))

	environment.fog_enabled = data["fog_enabled"]
	environment.fog_light_color = data["fog_color"]
	environment.fog_light_energy = data["fog_energy"]
	environment.fog_density = data["fog_density"]
	environment.fog_aerial_perspective = data["fog_aerial_perspective"]
	environment.fog_sky_affect = data["fog_sky_affect"]
	environment.fog_sun_scatter = data["fog_sun_scatter"]
	environment.fog_height = data["fog_height"]
	environment.fog_height_density = data["fog_height_density"]

	environment.ssao_enabled = data["ssao_enabled"]
	environment.ssao_radius = data["ssao_radius"]
	environment.ssao_intensity = data["ssao_intensity"]
	environment.ssao_power = data["ssao_power"]
	environment.ssao_light_affect = data["ssao_light_affect"]

	environment.ssr_enabled = data["ssr_enabled"]
	environment.ssr_max_steps = data["ssr_max_steps"]
	environment.ssr_fade_in = data["ssr_fade_in"]
	environment.ssr_fade_out = data["ssr_fade_out"]

	environment.volumetric_fog_enabled = data["volumetric_fog_enabled"]
	if bool(data["volumetric_fog_enabled"]):
		environment.volumetric_fog_density = data["volumetric_fog_density"]
		environment.volumetric_fog_albedo = data["volumetric_fog_albedo"]
		environment.volumetric_fog_anisotropy = data["volumetric_fog_anisotropy"]


static func _apply_sun(sun: DirectionalLight3D, data: Dictionary) -> void:
	sun.rotation_degrees = data["sun_angle"]
	sun.light_color = data["sun_color"]
	sun.light_energy = data["sun_energy"]
	sun.shadow_enabled = data["shadow_enabled"]
	if not bool(data["shadow_enabled"]):
		return
	sun.shadow_bias = data["shadow_bias"]
	sun.shadow_normal_bias = data["shadow_normal_bias"]
	sun.directional_shadow_max_distance = data["shadow_max_distance"]
	# A four-split cascade is what makes a 160 m lawn and a 220 m city both read
	# as sharp up close without shadows crawling under the player's feet.
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	# The sun also lights the sky, so the procedural sky's sun disc ends up where
	# the shadows say the sun is. A style that wants a flat gradient sky turns the
	# disc off instead — under a linear tone curve the disc is a blown-out blob,
	# and a painted sky has no business containing a photograph of a sun.
	sun.sky_mode = (
		DirectionalLight3D.SKY_MODE_LIGHT_AND_SKY
		if bool(data.get("sun_in_sky", true))
		else DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	)
	# Written unconditionally, including the zero a stylised preset asks for. An
	# angular distance is a shadow-filter cost, and a style that wants crisp cel
	# shadows has to be able to switch it *off* — which a "only when positive"
	# guard would silently refuse to do.
	sun.light_angular_distance = data.get("sun_angular_distance", 0.0)


static func _tonemap_for(key: StringName) -> Environment.ToneMapper:
	match key:
		&"linear":
			return Environment.TONE_MAPPER_LINEAR
		&"reinhard":
			return Environment.TONE_MAPPER_REINHARDT
		&"filmic":
			return Environment.TONE_MAPPER_FILMIC
		&"aces":
			return Environment.TONE_MAPPER_ACES
		_:
			return Environment.TONE_MAPPER_ACES


## Resolved from a string so the preset table stays readable, `&"bg"` being the
## engine default and therefore what the presets that predate this key ask for.
static func _reflection_source_for(key: StringName) -> Environment.ReflectionSource:
	match key:
		&"disabled":
			return Environment.REFLECTION_SOURCE_DISABLED
		&"sky":
			return Environment.REFLECTION_SOURCE_SKY
		_:
			return Environment.REFLECTION_SOURCE_BG
