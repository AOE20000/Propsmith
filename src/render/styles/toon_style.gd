extends RenderStyle
class_name ToonRenderStyle
## 3渲2 — a 3D scene drawn as if it were painted.
##
## Two halves, and both are needed:
##
##   1. **A flat environment.** No fog, no glow, no ambient occlusion, linear
##      tone mapping with the highlights left to clip, a near-flat sky and vivid
##      colour. Everything that makes a frame look photographic is turned off,
##      because cel banding on top of a graded, hazy image gives mud.
##   2. **A screen-space pass** (`toon_post.gdshader`) that quantises the light
##      into bands and inks the edges. Screen-space so it catches *everything* —
##      props, terrain, citizens, and whatever a mod spawns tomorrow — without
##      replacing a single material.
##
## The environment half is data, so it composes with any map: put this style on
## the dusk preset and the flat sky keeps dusk's colours. Only the photographic
## *treatment* is overridden, never the palette.

const POST_SHADER: Shader = preload("res://assets/shaders/toon_post.gdshader")
const SKY_SHADER: Shader = preload("res://assets/shaders/painted_sky.gdshader")

## Applied over whatever preset the map chose. The sky is replaced wholesale (see
## `paint_sky`), so the curve keys below are about the *procedural* sky a switch
## away from this style restores, not about what this style draws.
const FLAT_LOOK: Dictionary = {
	"tonemap": &"linear",
	"exposure": 0.9,
	"brightness": 1.0,
	"contrast": 1.0,
	"saturation": 1.45,
	"glow_enabled": false,
	"ssao_enabled": false,
	"ssr_enabled": false,
	"fog_enabled": false,
	"volumetric_fog_enabled": false,
	"ambient_energy": 0.9,
	"ambient_sky_contribution": 1.0,
	# Flat shading means no specular *at all*, and ambient specular is the one that
	# is easy to miss: it comes off the sky cubemap, varies with the reflection
	# vector, and on a large flat surface it lands as a broad soft blob that reads
	# as a smudge rather than as light. Off, the wall is one flat tone — which is
	# the whole point of the style.
	"reflected_light_source": &"disabled",
	# Crisp shadows: a soft-edged shadow is the most photographic thing a cel
	# frame can carry.
	"sun_angular_distance": 0.0,
	# No sun in the sky even if the sky were still procedural — belt and braces
	# against the blown-out disc.
	"sun_in_sky": false,
}


func style_id() -> StringName:
	return &"toon"


func display_name() -> String:
	return "3渲2"


func apply(context: Dictionary) -> bool:
	if not retune(context, FLAT_LOOK):
		return false
	paint_sky(context)
	return attach_screen_pass(context, POST_SHADER, "ToonPost") != null


func release() -> void:
	release_screen_pass()


## Swap the sky for the flat painted one, reading the map's own palette out of the
## preset it was built with.
##
## Nothing needs to be saved to undo this. `DemoLook.apply_to` rebuilds the sky
## material itself when it finds one it does not recognise, so the next style to
## apply — including 写实, which applies no overrides at all — gets a procedural
## sky back, tuned to the preset. Retuning rather than owning is what keeps that
## true, and this is the case that would have needed a saved handle under any
## other design.
func paint_sky(context: Dictionary) -> void:
	var world_environment: WorldEnvironment = context.get("environment") as WorldEnvironment
	if world_environment == null or world_environment.environment == null:
		return
	var sky: Sky = world_environment.environment.sky
	if sky == null:
		sky = Sky.new()
		world_environment.environment.sky = sky
	var palette: Dictionary = DemoLook.preset(DemoLook.preset_of(world_environment))
	var material := ShaderMaterial.new()
	material.shader = SKY_SHADER
	material.set_shader_parameter(&"zenith_color", palette.get("sky_top", Color(0.33, 0.52, 0.80)))
	material.set_shader_parameter(&"horizon_color", palette.get("sky_horizon", Color(0.86, 0.85, 0.79)))
	material.set_shader_parameter(&"ground_color", palette.get("ground_bottom", Color(0.34, 0.32, 0.28)))
	sky.sky_material = material
