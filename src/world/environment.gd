extends Node
class_name WorldEnvironment3D
## Sky, sun, fog and sea for the island. A separate stage so the lighting mood can
## be replaced without touching terrain or gameplay.

const SEA_SIZE: float = 4096.0
## Sea surface sits at this height; `TerrainQuery.WATER_LEVEL` must match.
const SEA_LEVEL: float = 0.0

var world_environment: WorldEnvironment = null
var sun: DirectionalLight3D = null
var sea: MeshInstance3D = null
var sea_material: ShaderMaterial = null

## Seconds for a full day; 0 disables the cycle and freezes the sun.
@export var day_length_seconds: float = 600.0
@export var time_of_day: float = 0.28


func build(parent: Node3D, config: TerrainConfig) -> void:
	_build_environment(parent, config)
	_build_sun(parent)
	_build_sea(parent)
	set_process(day_length_seconds > 0.0)


func _process(delta: float) -> void:
	if day_length_seconds <= 0.0:
		return
	time_of_day = fposmod(time_of_day + delta / day_length_seconds, 1.0)
	_apply_sun_angle()
	if sea_material != null:
		sea_material.set_shader_parameter("time_seconds", Time.get_ticks_msec() / 1000.0)


func _build_environment(parent: Node3D, config: TerrainConfig) -> void:
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.22, 0.42, 0.72)
	sky_material.sky_horizon_color = Color(0.69, 0.78, 0.86)
	sky_material.ground_bottom_color = Color(0.16, 0.19, 0.21)
	sky_material.ground_horizon_color = Color(0.42, 0.45, 0.45)
	sky_material.sun_angle_max = 12.0
	sky_material.sun_curve = 0.12

	var sky := Sky.new()
	sky.sky_material = sky_material

	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_sky_contribution = 1.0
	environment.ambient_light_energy = 0.9
	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	environment.tonemap_white = 6.0
	environment.ssao_enabled = true
	environment.ssao_radius = 2.0
	environment.ssao_intensity = 1.6

	# Aerial perspective does most of the work of selling distance on a small map.
	environment.fog_enabled = true
	environment.fog_mode = Environment.FOG_MODE_DEPTH
	environment.fog_light_color = Color(0.68, 0.75, 0.82)
	environment.fog_light_energy = 1.0
	environment.fog_density = 0.0016
	environment.fog_aerial_perspective = 0.55
	environment.fog_sky_affect = 0.25
	environment.fog_depth_begin = 80.0
	environment.fog_depth_end = maxf(config.island_radius * 3.0, 600.0)

	environment.adjustment_enabled = true
	environment.adjustment_saturation = 1.06
	environment.adjustment_contrast = 1.04

	world_environment = WorldEnvironment.new()
	world_environment.name = "WorldEnvironment"
	world_environment.environment = environment
	parent.add_child(world_environment)


func _build_sun(parent: Node3D) -> void:
	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_energy = 1.15
	sun.light_color = Color(1.0, 0.96, 0.88)
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 220.0
	sun.directional_shadow_split_1 = 0.08
	sun.directional_shadow_split_2 = 0.22
	sun.directional_shadow_split_3 = 0.5
	sun.shadow_bias = 0.04
	parent.add_child(sun)
	_apply_sun_angle()


func _apply_sun_angle() -> void:
	if sun == null:
		return
	# Elevation follows a sine so dawn and dusk pass quickly, noon lingers.
	var angle: float = time_of_day * TAU - PI * 0.5
	var elevation: float = sin(angle)
	sun.rotation = Vector3(-elevation * 1.15, time_of_day * TAU + PI * 0.25, 0.0)
	sun.light_energy = clampf(0.15 + elevation * 1.3, 0.08, 1.25)
	sun.light_color = Color(1.0, 0.9, 0.78).lerp(Color(1.0, 0.98, 0.95), clampf(elevation, 0.0, 1.0))


func _build_sea(parent: Node3D) -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(SEA_SIZE, SEA_SIZE)
	plane.subdivide_width = 64
	plane.subdivide_depth = 64

	sea_material = ShaderMaterial.new()
	sea_material.shader = _sea_shader()
	sea_material.set_shader_parameter("shallow_color", Color(0.16, 0.45, 0.52))
	sea_material.set_shader_parameter("deep_color", Color(0.02, 0.11, 0.22))
	sea_material.set_shader_parameter("wave_height", 0.28)
	sea_material.set_shader_parameter("wave_scale", 0.09)
	sea_material.set_shader_parameter("time_seconds", 0.0)

	sea = MeshInstance3D.new()
	sea.name = "Sea"
	sea.mesh = plane
	sea.material_override = sea_material
	sea.position = Vector3(0.0, SEA_LEVEL, 0.0)
	sea.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(sea)


## Small hand-written shader: gerstner-ish sum of two sine waves plus a depth
## tint. Kept inline so the sea has no external asset dependency.
func _sea_shader() -> Shader:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec3 shallow_color : source_color = vec3(0.16, 0.45, 0.52);
uniform vec3 deep_color : source_color = vec3(0.02, 0.11, 0.22);
uniform float wave_height = 0.28;
uniform float wave_scale = 0.09;
uniform float time_seconds = 0.0;

float wave(vec2 p, vec2 dir, float freq, float speed) {
	return sin(dot(p, dir) * freq + time_seconds * speed);
}

void vertex() {
	vec2 p = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
	float h = 0.0;
	h += wave(p, normalize(vec2(1.0, 0.35)), wave_scale, 1.1) * wave_height;
	h += wave(p, normalize(vec2(-0.4, 1.0)), wave_scale * 1.7, 1.6) * wave_height * 0.55;
	h += wave(p, normalize(vec2(0.7, -0.7)), wave_scale * 3.1, 2.3) * wave_height * 0.22;
	VERTEX.y += h;

	vec3 tangent = vec3(1.0, 0.0, 0.0);
	float dx = cos(dot(p, normalize(vec2(1.0, 0.35))) * wave_scale + time_seconds * 1.1) * wave_height * wave_scale;
	float dz = cos(dot(p, normalize(vec2(-0.4, 1.0))) * wave_scale * 1.7 + time_seconds * 1.6) * wave_height * 0.55 * wave_scale * 1.7;
	NORMAL = normalize(vec3(-dx, 1.0, -dz));
}

void fragment() {
	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	ALBEDO = mix(deep_color, shallow_color, fresnel * 0.85 + 0.15);
	ROUGHNESS = mix(0.06, 0.22, fresnel);
	METALLIC = 0.0;
	SPECULAR = 0.6;
	ALPHA = 0.93;
}
"""
	return shader
