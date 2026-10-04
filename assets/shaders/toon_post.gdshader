shader_type spatial;
// A post-process pass, not a surface. Runs on a `ScreenPass` quad sitting in
// front of the active camera, which is what makes the depth buffer available —
// `canvas_item` shaders cannot sample it, and the ink line needs depth.
//
// Painting over an existing image rather than shading a surface: `unshaded` so
// nothing lights it, `depth_test_disabled` so it is never occluded, and `ALPHA`
// written so it composites in the transparent pass — after everything else, and
// therefore *over* everything else rather than instead of it.
render_mode unshaded, depth_test_disabled, depth_draw_never, cull_disabled;

// The 3渲2 look, as an overlay on the finished frame.
//
// Screen-space on purpose. Doing this per material would mean replacing the
// material of every prop, terrain patch, character and mod-added mesh — and a
// style that only cel-shades the content it happens to know about is not a
// style, it is a bug report. One pass over the backbuffer catches all of it,
// including whatever a mod spawns tomorrow.
//
// ## Why an overlay and not a replacement
//
// `hint_screen_texture` on a 3D material is the **opaque pass** copy: transparent
// geometry cannot see other transparent geometry, so the pond and the water in it
// are simply absent from the image this shader reads. Replacing the frame would
// therefore erase every transparent surface in the game — the first version of
// this file did exactly that, and the pond came out as an empty pit.
//
// Compositing instead means the copy is only ever used to decide *how to shift*
// the real frame. For the opaque majority the shift is exact: with the overlay
// colour pinned to white or black, `alpha` can be solved so that
// `overlay * alpha + frame * (1 - alpha)` lands on the banded value, whatever the
// frame held. Over a transparent surface the same alpha applies a band structure
// taken from what is behind it, which is a smooth field rather than a wrong colour
// — and the surface keeps its own colour, which is the part that matters.
//
// ## What this can and cannot do
//
// It bands the *finished* frame, so it also bands things that were never lit —
// and a large flat surface whose lightness happens to sit near a band boundary
// gets that boundary drawn across it as a soft contour, following whatever faint
// luminance drift the surface has. A wall in this map showed two such arcs, and
// they were diagnosed rather than guessed at: a magenta debug fill proved the
// banded region was the wall's own shallow gradient. Dithering the band edge
// softens it but cannot remove it, because the *average* lightness still steps.
//
// The honest fix is to band the lighting rather than the image — per material,
// where a band boundary lands in a meaningful place (a terminator, a fold) instead
// of wherever the arithmetic put it. That is what MToon does for the characters
// (see `addons/Godot-MToon-Shader`), and extending it to props and terrain is the
// next step for this style, not something a screen-space pass can reach.

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;

// One screen pixel in UV, pushed by the `ScreenPass` quad that draws this. A
// uniform rather than `SCREEN_PIXEL_SIZE`, which is a canvas-shader builtin and
// does not exist in a spatial shader. The default below only covers the first
// frame, before the pass has pushed a real value.
uniform vec2 screen_pixel_size = vec2(0.0007);

// How many steps the light is quantised into. 0 or 1 would flatten the image to
// a silhouette; the look wants enough bands to read form, few enough to read
// as painted.
uniform int bands : hint_range(2, 12) = 5;
// The darkest band is lifted off zero. A cel frame does want a hard shadow, but
// quantising to exactly black erases the shadow's own colour and turns every
// surface facing away from the sun into a silhouette — the boundary wall in this
// very map is the example: one flat black wedge, no form left in it.
uniform float black_floor : hint_range(0.0, 0.4) = 0.12;
// How much of the band structure to actually apply. 1.0 is a hard cel step; a
// little under keeps the steps visible while softening the band boundaries that
// fall over a transparent surface, where the band field is read from whatever is
// behind it rather than from the surface itself.
uniform float band_strength : hint_range(0.0, 1.0) = 0.85;
uniform float edge_strength : hint_range(0.0, 4.0) = 1.4;
// Multiplier on the relative depth step that counts as an edge, tuned against a
// 4 % step being texture and a 13 % step being a silhouette.
uniform float depth_edge_sensitivity : hint_range(1.0, 120.0) = 24.0;
uniform float color_edge_threshold : hint_range(0.0, 1.0) = 0.10;
uniform vec3 ink_color : source_color = vec3(0.05, 0.05, 0.09);
uniform float vignette : hint_range(0.0, 1.0) = 0.16;

const vec3 LUMA_WEIGHTS = vec3(0.2126, 0.7152, 0.0722);


float luma(vec3 color) {
	return dot(color, LUMA_WEIGHTS);
}


// A monotonic stand-in for distance, read straight from the opaque depth buffer.
//
// Godot's depth is reversed-Z, so the raw value shrinks with distance and its
// reciprocal grows with it — and the *relative* difference of that reciprocal is
// the relative difference of distance itself, which is exactly what an edge test
// wants. Deliberately not a real reconstruction: that needs
// `INV_PROJECTION_MATRIX`, which an `unshaded` spatial shader does not expose,
// and a relative test is answered just as well by any monotonic quantity.
//
// The clamp keeps the clear value (sky, where nothing was drawn) from dividing by
// zero, and lands it at the extreme of the range whatever that value happens to
// be — so sky against anything is always a large step, with no special case.
float distance_proxy(vec2 uv) {
	return 1.0 / clamp(texture(depth_texture, uv).r, 0.00002, 1.0);
}


// Symmetric relative difference: a 10 % step is a 10 % step whether it happens at
// 3 m or at 300 m. An absolute threshold would be noise nearby and blind far away,
// and this scene spans both.
float relative_step(float a, float b) {
	return abs(a - b) / max(max(a, b), 1.0);
}


float quantise(float value, float count) {
	return floor(value * count + 0.5) / count;
}


// Whether nothing was drawn at this pixel — i.e. the sky.
//
// Tested against *both* ends of the depth range rather than the one this shader
// expects: `hint_depth_texture` is documented as [0, 1] with 1 at the far plane,
// but a reversed-Z pipeline clears to the other end, and a wrong guess here is
// silent — it simply leaves the sky being banded, which is the artefact this
// guard exists to prevent. No scene has real geometry at either extreme, so
// accepting both is free.
bool is_sky(float raw_depth) {
	return raw_depth <= 0.00002 || raw_depth >= 0.99998;
}


void fragment() {
	vec2 step_size = screen_pixel_size;
	vec3 source = texture(screen_texture, SCREEN_UV).rgb;

	float center_proxy = distance_proxy(SCREEN_UV);
	float center_luma = luma(source);

	// A four-tap cross, unrolled. A full Sobel on a look this stylised buys
	// nothing visible, and the ink line is meant to be a drawn line, not a
	// photograph of one.
	float d_left = distance_proxy(SCREEN_UV + vec2(-step_size.x, 0.0));
	float d_right = distance_proxy(SCREEN_UV + vec2(step_size.x, 0.0));
	float d_down = distance_proxy(SCREEN_UV + vec2(0.0, -step_size.y));
	float d_up = distance_proxy(SCREEN_UV + vec2(0.0, step_size.y));

	float depth_edge = 0.0;
	depth_edge = max(depth_edge, relative_step(d_left, center_proxy));
	depth_edge = max(depth_edge, relative_step(d_right, center_proxy));
	depth_edge = max(depth_edge, relative_step(d_down, center_proxy));
	depth_edge = max(depth_edge, relative_step(d_up, center_proxy));

	float l_left = luma(texture(screen_texture, SCREEN_UV + vec2(-step_size.x, 0.0)).rgb);
	float l_right = luma(texture(screen_texture, SCREEN_UV + vec2(step_size.x, 0.0)).rgb);
	float l_down = luma(texture(screen_texture, SCREEN_UV + vec2(0.0, -step_size.y)).rgb);
	float l_up = luma(texture(screen_texture, SCREEN_UV + vec2(0.0, step_size.y)).rgb);

	float luma_edge = 0.0;
	luma_edge = max(luma_edge, abs(l_left - center_luma));
	luma_edge = max(luma_edge, abs(l_right - center_luma));
	luma_edge = max(luma_edge, abs(l_down - center_luma));
	luma_edge = max(luma_edge, abs(l_up - center_luma));

	// Silhouettes come from depth; the colour term only adds the interior lines
	// a flat-shaded scene has no depth step for.
	float depth_term = smoothstep(1.0, 3.0, depth_edge * depth_edge_sensitivity);
	float color_term = smoothstep(color_edge_threshold, color_edge_threshold * 2.5, luma_edge) * 0.7;
	float ink = clamp(max(depth_term, color_term) * edge_strength, 0.0, 1.0);

	// --- banding, as a solved overlay ---
	//
	// The target lightness is the quantised one. Blending towards white can only
	// raise the frame and towards black can only lower it, so the alpha that lands
	// exactly on the target is solvable when the frame equals `source` — which is
	// true for every opaque pixel, and approximately true elsewhere.
	float base = max(center_luma, 0.0001);
	float target = max(quantise(base, float(bands)), black_floor);
	// The sky is left alone. It carries no depth, and it is already a flat painted
	// field — quantising a smooth gradient produces nothing but plateaus and arcs.
	// That is not a theory: the two soft arcs that used to sit just under the
	// horizon in this map's pond shots were the sky's lower hemisphere being
	// banded, and they survived every change to the lighting before this guard
	// was fixed to test the right end of the depth range.
	float band_mask = is_sky(texture(depth_texture, SCREEN_UV).r) ? 0.0 : 1.0;
	float delta = (target - base) * band_strength * band_mask;

	vec3 overlay = delta >= 0.0 ? vec3(1.0) : vec3(0.0);
	float alpha = delta >= 0.0
		? delta / max(1.0 - base, 0.02)
		: -delta / max(base, 0.02);

	// An ink line is a statement; a band edge is a field. The line wins outright.
	if (ink > alpha) {
		overlay = ink_color;
		alpha = ink;
	}

	// Vignette last: it only ever darkens, so it can merely win on strength.
	vec2 centred = SCREEN_UV - vec2(0.5);
	float vig = vignette * dot(centred, centred) * 2.0;
	if (vig > alpha) {
		overlay = vec3(0.0);
		alpha = vig;
	}

	ALBEDO = clamp(overlay, vec3(0.0), vec3(1.0));
	ALPHA = clamp(alpha, 0.0, 1.0);
}
