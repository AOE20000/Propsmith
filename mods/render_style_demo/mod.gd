extends ModBase
## Demonstration mod for the render-style extension point: the answer to "can a
## mod change how the game is drawn".
##
## Two styles, one of each shape the seam offers:
##
##   - **黄金时刻** — `add_render_style_preset`: nothing but a table of look
##     overrides. Eight lines, no shader, no subclass. This is the shape most mods
##     want, and the only one a scripted (Lua / sandboxed) mod can use, because it
##     ships no code.
##   - **黑白电影** — `add_render_style`: a `RenderStyle` subclass carrying its own
##     screen-space shader. The escape hatch for a mod that needs to draw
##     something no override table can express.
##
## Neither touches world state, and that is the contract rather than a coincidence:
## a render style is a way of *looking at* the world, so switching away has to
## leave the world exactly as it was found.

func _on_register() -> void:
	display_name = "画风演示"
	version = "1.0.0"
	author = "example"

	# The whole cost of a data-only style. Every key is a `DemoLook` key, applied
	# over whatever preset the map authored — so 黄金时刻 on the city keeps the
	# city's fog depth and gains a low warm sun.
	context.add_render_style_preset(&"golden_hour", "黄金时刻", {
		"sun_angle": Vector3(-16.0, -62.0, 0.0),
		"sun_color": Color(1.0, 0.80, 0.52),
		"sun_energy": 1.5,
		"sky_top": Color(0.30, 0.34, 0.62),
		"sky_horizon": Color(0.98, 0.72, 0.42),
		"ground_horizon": Color(0.62, 0.42, 0.34),
		"fog_color": Color(0.92, 0.70, 0.50),
		"fog_density": 0.003,
		"exposure": 1.05,
		"saturation": 1.18,
	})

	context.add_render_style(&"noir", "黑白电影", _make_noir)

	log_message("已注册画风：黄金时刻（数据式）、黑白电影（自带 shader）")


func _make_noir() -> RenderStyle:
	return NoirStyle.new()


## A style with its own shader. The environment half goes monochrome through
## overrides; the film half — contrast, grain, vignette — is a screen-space pass,
## because none of it is expressible as an environment value.
##
## Written as an inner class rather than a second file with a `class_name`: a mod
## that declares a global class pollutes a namespace shared with every other mod,
## and the id it registers under is already its name.
class NoirStyle extends RenderStyle:
	## `preload` on the mod's own asset: a mod ships its shader next to its code,
	## and this is the same path form the built-in styles use.
	const POST_SHADER: Shader = preload("res://mods/render_style_demo/noir.gdshader")

	## Applied over the map's preset. Fog is deliberately left alone — monochrome
	## is the whole point, and the map's haze reads better in grey than anything
	## this style could pick for it.
	const LOOK: Dictionary = {
		"saturation": 0.0,
		"glow_enabled": false,
		"ssao_enabled": false,
		"ssr_enabled": false,
		"contrast": 1.15,
	}

	func style_id() -> StringName:
		return &"noir"

	func display_name() -> String:
		return "黑白电影"

	func apply(context: Dictionary) -> bool:
		if not retune(context, LOOK):
			return false
		return attach_screen_pass(context, POST_SHADER, "NoirPost") != null

	func release() -> void:
		release_screen_pass()


func _on_tick(_delta: float) -> void:
	pass


func serialize() -> Dictionary:
	return {}


func deserialize(_data: Dictionary) -> void:
	pass
