shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_back, diffuse_burley, specular_schlick_ggx;
// Stylised water for the demo's pond.
//
// Why not real reflections: `Environment`'s screen-space reflections are
// composited during the *opaque* pass, so a transparent water surface never
// receives them. Physical reflection would therefore need a reflection probe or
// a planar mirror camera — both of which cost a full extra render of the scene
// for one pond. Instead this shader fakes the only reflection that matters at a
// glance: a fresnel-weighted blend between the water's own colour and a sky
// gradient read straight off the wave normal, which makes the reflection move
// with the ripples exactly as a real one would.
//
// Depth is read from the opaque depth buffer, so the surface knows how much
// water is under it and grades from clear-at-the-shore to opaque-in-the-middle.
// That gradient — plus the foam line it draws along the bank — is what sells a
// two-metre pond as water rather than as blue paint.
//
// Spaces: the view-space position is carried through as a varying rather than
// read back from `VERTEX`, so the fresnel and the depth comparison are built from
// one explicitly-named quantity. `MODELVIEW_MATRIX` is unambiguous in the vertex
// stage; what `VERTEX` means in the fragment stage is not something this shader
// should have to have an opinion about.

// Water body colour, shallow (sunlit, you can see the bottom) to deep. The deep
// end is a saturated blue rather than near-black: a pond two metres down still
// holds sky light, and a black pond reads as a hole.
uniform vec3 shallow_color : source_color = vec3(0.22, 0.50, 0.47);
uniform vec3 deep_color : source_color = vec3(0.03, 0.16, 0.26);

// The fake reflection: the sky as seen from a wave. Horizon and zenith are
// enough — the wave normal already sweeps between the two as the surface tilts.
uniform vec3 reflection_horizon : source_color = vec3(0.74, 0.82, 0.88);
uniform vec3 reflection_zenith : source_color = vec3(0.31, 0.49, 0.76);

// The line of disturbed water where the pond meets its bank.
uniform vec3 foam_color : source_color = vec3(0.83, 0.90, 0.90);
uniform float foam_width : hint_range(0.0, 0.5) = 0.10;
uniform float foam_strength : hint_range(0.0, 1.0) = 0.45;

// Wave field. `wave_scale` is frequency in radians per metre, so the four
// octaves below land around 3-7 m — pond ripples, not ocean swell. On an 18 m
// pond the longer wavelengths would put half a wave across the whole surface and
// read as one tilting sheet.
uniform float wave_scale : hint_range(0.05, 6.0) = 1.6;
uniform float wave_speed : hint_range(0.0, 2.0) = 0.8;
uniform float wave_height : hint_range(0.0, 0.4) = 0.09;
// How much the wave slope is exaggerated when building the normal. 1.0 is
// physically honest and looks flat; a stylised surface wants more.
uniform float normal_strength : hint_range(0.0, 3.0) = 1.2;

uniform float fresnel_power : hint_range(1.0, 12.0) = 5.0;
// Distance over which the colour reaches `deep_color`. The pond is under two
// metres deep, so this is set wider than that on purpose: a shallow pond should
// never quite reach its deepest colour, or the whole surface goes flat.
uniform float depth_scale : hint_range(0.1, 12.0) = 3.0;
uniform float shallow_alpha : hint_range(0.0, 1.0) = 0.40;
uniform float deep_alpha : hint_range(0.0, 1.0) = 0.94;
// Brightness ripple riding the same wave field, so the water is not a flat field
// of colour even where the depth gradient does not change.
uniform float shimmer : hint_range(0.0, 0.4) = 0.08;

uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;

varying vec3 v_view_pos;
varying vec3 v_view_normal;
varying vec3 v_world_normal;
varying float v_ripple;

// Wave directions, shared by the height field and its gradient so the surface
// and its normals can never drift apart. Deliberately not axis-aligned: four
// plane waves along X and Z interfere into a visible plaid, and rotating each
// one costs nothing.
const vec2 WAVE_DIR_1 = vec2(0.86, 0.51);
const vec2 WAVE_DIR_2 = vec2(-0.42, 0.91);
const vec2 WAVE_DIR_3 = vec2(0.71, -0.71);
const vec2 WAVE_DIR_4 = vec2(-0.93, -0.37);

const float WAVE_AMP_1 = 0.55;
const float WAVE_AMP_2 = 0.45;
const float WAVE_AMP_3 = 0.30;
const float WAVE_AMP_4 = 0.18;

const float WAVE_FREQ_2 = 0.83;
const float WAVE_FREQ_3 = 0.55;
const float WAVE_FREQ_4 = 1.37;


// Height of the wave field at a world XZ position: four sines at unrelated
// frequencies, speeds and directions. Enough to avoid an obvious repeating
// grid, cheap enough to run per vertex on a subdivided plane.
float wave_height_at(vec2 p, float t) {
	float h = 0.0;
	h += sin(dot(p, WAVE_DIR_1) * wave_scale + t * 1.15) * WAVE_AMP_1;
	h += sin(dot(p, WAVE_DIR_2) * wave_scale * WAVE_FREQ_2 - t * 0.87) * WAVE_AMP_2;
	h += sin(dot(p, WAVE_DIR_3) * wave_scale * WAVE_FREQ_3 + t * 1.70) * WAVE_AMP_3;
	h += sin(dot(p, WAVE_DIR_4) * wave_scale * WAVE_FREQ_4 - t * 2.30) * WAVE_AMP_4;
	return h;
}


// Analytic gradient of the same field — cheaper and smoother than sampling the
// height at offsets, and it keeps the normal in step with the displacement.
// `d/dp sin(dot(p, d) * k + phi) = d * k * cos(...)`.
vec2 wave_gradient_at(vec2 p, float t) {
	vec2 g = vec2(0.0);
	g += WAVE_DIR_1 * cos(dot(p, WAVE_DIR_1) * wave_scale + t * 1.15) * WAVE_AMP_1 * wave_scale;
	g += WAVE_DIR_2 * cos(dot(p, WAVE_DIR_2) * wave_scale * WAVE_FREQ_2 - t * 0.87) * WAVE_AMP_2 * wave_scale * WAVE_FREQ_2;
	g += WAVE_DIR_3 * cos(dot(p, WAVE_DIR_3) * wave_scale * WAVE_FREQ_3 + t * 1.70) * WAVE_AMP_3 * wave_scale * WAVE_FREQ_3;
	g += WAVE_DIR_4 * cos(dot(p, WAVE_DIR_4) * wave_scale * WAVE_FREQ_4 - t * 2.30) * WAVE_AMP_4 * wave_scale * WAVE_FREQ_4;
	return g;
}


void vertex() {
	// World XZ, not model XZ: neighbouring water tiles (or a second pond) then
	// share one continuous wave field instead of each rippling in its own frame.
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float t = TIME * wave_speed;

	float h = wave_height_at(world_pos.xz, t);
	VERTEX.y += h * wave_height;

	vec2 slope = wave_gradient_at(world_pos.xz, t) * wave_height * normal_strength;
	vec3 n_world = normalize(vec3(-slope.x, 1.0, -slope.y));

	// Displacement first, then transforms — the wave has to be in the position
	// the fragment stage will measure its depth from.
	v_view_pos = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = n_world;
	v_view_normal = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);
	v_ripple = h;
}


void fragment() {
	vec3 n_view = normalize(v_view_normal);
	NORMAL = n_view;

	// Fresnel from the actual wave normal: water turns into a mirror when seen
	// edge-on, which is what makes a low camera angle read as "water" and what
	// puts the sky into the ripples.
	vec3 view_dir = normalize(-v_view_pos);
	float fres = pow(1.0 - clamp(dot(n_view, view_dir), 0.0, 1.0), fresnel_power);

	// How much water is between this fragment and whatever is behind it. The
	// opaque pass has already run, so the depth buffer holds the pond floor.
	float raw_depth = texture(depth_texture, SCREEN_UV).r;
	vec4 scene_view = INV_PROJECTION_MATRIX * vec4(vec3(SCREEN_UV * 2.0 - 1.0, raw_depth), 1.0);
	scene_view.xyz /= scene_view.w;
	float scene_distance = -scene_view.z;
	float surface_distance = -v_view_pos.z;
	float water_depth = max(scene_distance - surface_distance, 0.0);
	float depth_factor = clamp(water_depth / max(depth_scale, 0.001), 0.0, 1.0);

	vec3 water = mix(shallow_color, deep_color, depth_factor);
	water *= 1.0 + v_ripple * shimmer;

	float up = clamp(v_world_normal.y, 0.0, 1.0);
	vec3 sky = mix(reflection_horizon, reflection_zenith, pow(up, 0.6));

	vec3 color = mix(water, sky, fres);
	// Foam along the bank, jogged by the wave field so the line is not a
	// mathematical contour. It is the cheapest cue that says "this is a surface
	// meeting a shore" rather than "this is a blue rectangle".
	float foam = (1.0 - smoothstep(0.0, foam_width, depth_factor));
	foam *= foam_strength * (0.8 + 0.15 * clamp(v_ripple, -1.0, 1.0));

	ALBEDO = mix(color, foam_color, clamp(foam, 0.0, 1.0));
	// Calm water is nearly a mirror; the wave crests scatter. Tying roughness to
	// the same fresnel term is what puts a sun glint on the ripple faces.
	ROUGHNESS = mix(0.45, 0.04, fres);
	METALLIC = 0.0;
	SPECULAR = 0.4;
	ALPHA = mix(shallow_alpha, deep_alpha, depth_factor);
}
