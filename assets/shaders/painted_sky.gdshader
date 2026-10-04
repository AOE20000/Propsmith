shader_type sky;

// A painted sky: two colours and a curve between them, and nothing else.
//
// The procedural sky is a lighting model — a sun disc, an atmospheric falloff,
// optional clouds. Under a linear tone curve the disc blows out into a blob, and
// posterising a lighting model leaves visible plateaus inside what should be a
// flat field. A style that draws the sky by hand should not be shading a
// photograph of one, so this replaces the model rather than tuning it.
//
// It reads the same two colours the map's preset does, so 3渲2 on the dusk preset
// still gets dusk's palette — the style changes the *treatment*, never the
// palette.
//
// With no sun term there is no sun in the sky, which also means no disc, no
// halo, and nothing for the cel pass to quantise into rings.

uniform vec3 zenith_color : source_color = vec3(0.33, 0.52, 0.80);
uniform vec3 horizon_color : source_color = vec3(0.86, 0.85, 0.79);
uniform vec3 ground_color : source_color = vec3(0.34, 0.32, 0.28);
// Exponent on the elevation. 1.0 is a linear ramp; below 1 flattens the band
// just above the horizon, which is where a painted sky keeps most of its colour.
uniform float curve : hint_range(0.05, 2.0) = 0.7;
uniform float energy : hint_range(0.0, 2.0) = 1.0;


void sky() {
	// `EYEDIR.y` is the sine of the elevation: 0 at the horizon, 1 straight up.
	float elevation = EYEDIR.y;
	float above = pow(clamp(elevation, 0.0, 1.0), curve);
	float below = pow(clamp(-elevation, 0.0, 1.0), curve);

	// Below the horizon the sky is the ground plane's colour, so looking down a
	// hole in the terrain does not reveal blue.
	vec3 lower = mix(horizon_color, ground_color, below);
	vec3 upper = mix(horizon_color, zenith_color, above);

	COLOR = mix(lower, upper, step(0.0, elevation)) * energy;
}
