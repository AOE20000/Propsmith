shader_type spatial;
// A mod-shipped post-process pass: high-contrast monochrome with grain and a
// vignette, so the frame reads as film rather than as a desaturated screenshot.
//
// A `spatial` shader on a `ScreenPass` quad, matching what the core's styles use
// — see `toon_post.gdshader` for why an overlay would not do.
//
// This file exists to prove a point rather than to be pretty on its own: a mod
// that needs to draw something no override table can express can ship a shader
// and attach it through the same `attach_screen_pass` the built-in styles use.
render_mode unshaded, depth_test_disabled, depth_draw_never, cull_disabled;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;

uniform float contrast : hint_range(0.5, 3.0) = 1.9;
uniform float lift : hint_range(-0.3, 0.3) = -0.05;
uniform float grain : hint_range(0.0, 0.2) = 0.05;
uniform float vignette : hint_range(0.0, 1.0) = 0.5;

const vec3 LUMA_WEIGHTS = vec3(0.2126, 0.7152, 0.0722);


// Deterministic per-pixel hash: the grain has to move every frame, and `TIME` is
// pushed through one of the inputs rather than into a separate noise texture.
float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}


void fragment() {
	vec3 source = texture(screen_texture, SCREEN_UV).rgb;
	float luma = dot(source, LUMA_WEIGHTS);

	luma = (luma - 0.5) * contrast + 0.5 + lift;
	luma += (hash(SCREEN_UV * vec2(1920.0, 1080.0) + vec2(TIME)) - 0.5) * grain;

	vec2 centred = SCREEN_UV - vec2(0.5);
	luma *= 1.0 - vignette * dot(centred, centred) * 2.0;

	ALBEDO = vec3(clamp(luma, 0.0, 1.0));
	ALPHA = 1.0;
}
