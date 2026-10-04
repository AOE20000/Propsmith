extends RefCounted
class_name RenderStyle
## The seam between "the game" and "how the frame is drawn".
##
## A render style owns **presentation** — the `Environment`, screen-space passes,
## project-level render settings — and never world state. Mods register styles
## through the same seam the core uses, so "写实" and "3渲2" are not special cases
## in the engine: they are two entries in a table that a mod can add to.
##
## ## The contract is a pair of calls, and the pair is the whole design
##
## `apply()` is handed handles to the live presentation nodes. It must not assume
## it is the first style ever applied, and it must not assume the handles stay
## valid — every `map_source.build()` replaces the `WorldEnvironment`, so the
## director re-applies the active style on `Events.world_ready` and `release()`s
## it first. Whatever `apply()` adds to the scene, `release()` takes away.
##
## ## Why styles retune rather than own the environment
##
## The obvious design is "a style builds its own sky". That design cannot answer
## *what happens when you switch back*. This one can: `DemoLook.apply_to()` is a
## pure function of (preset, overrides), so a style is a set of deviations from
## the map's authored look and switching is just re-deriving. There is no state to
## save, nothing to forget to restore, and a map's own mood survives a round trip
## through any style — including one written by a mod that has never seen it.

## The pass `attach_screen_pass` installed, held so `release()` can take it away.
var _screen_pass: ScreenPass = null


## The id this style registers under; also its save identity. Empty means the
## subclass forgot to override it, which the catalog reports rather than guesses.
func style_id() -> StringName:
	return &""


func display_name() -> String:
	return String(style_id())


## One line for the debug overlay and the boot report.
func describe() -> String:
	return String(display_name())


## Bring the frame into this style. `context` carries
## `{world, environment, sun, host, viewport}`; `host` is a node the style may
## parent passes to, and every handle in it may be null on a map that has no
## environment yet. Returns false when the style could not be applied, in which
## case the director keeps the previous one.
func apply(_context: Dictionary) -> bool:
	return false


## Undo `apply()`. Must be safe to call when `apply()` returned false or was never
## called, because the director releases defensively on every switch and on the
## way out of a session.
func release() -> void:
	pass


## Retune the world's environment to `preset` plus `overrides`, and nothing else.
##
## The shared implementation behind every style that is "the map's look, but…" —
## which is nearly all of them. An empty `overrides` restores the preset exactly,
## which is how a style hands the frame back: `DemoLook.apply_to` writes every key
## unconditionally, so one call is a full reset rather than a partial patch.
func retune(context: Dictionary, overrides: Dictionary = {}) -> bool:
	var world_environment: WorldEnvironment = context.get("environment") as WorldEnvironment
	var sun: DirectionalLight3D = context.get("sun") as DirectionalLight3D
	if world_environment == null or world_environment.environment == null or sun == null:
		push_warning("[render] style '%s': the world has no environment to retune" % style_id())
		return false
	return DemoLook.apply_to(world_environment.environment, sun, DemoLook.preset_of(world_environment), overrides)


## Parent a full-screen shader pass over the frame, and keep the handle so
## `release_screen_pass()` can take it away again.
##
## The pass is a `ScreenPass` quad in the 3D scene, not a `CanvasLayer` overlay,
## because it needs the depth buffer (see `ScreenPass` for why that rules the
## overlay out). It positions itself in front of whatever camera is active, so a
## style does not have to care which one that is, or notice when it changes.
##
## The shader must be a `spatial` shader. Returns the pass, or null when the
## context cannot carry one.
func attach_screen_pass(context: Dictionary, shader: Shader, pass_name: String = "ScreenPass") -> ScreenPass:
	var host: Node = context.get("host") as Node
	if host == null or shader == null:
		push_warning("[render] style '%s': a screen pass needs a host node and a shader" % style_id())
		return null
	var material := ShaderMaterial.new()
	material.shader = shader
	var pass_node := ScreenPass.new()
	pass_node.name = pass_name
	pass_node.material_override = material
	host.add_child(pass_node)
	_screen_pass = pass_node
	return pass_node


## Undo `attach_screen_pass`. Safe when nothing was attached, so a `release()`
## that only calls this needs no guard of its own.
func release_screen_pass() -> void:
	if _screen_pass != null and is_instance_valid(_screen_pass):
		_screen_pass.queue_free()
	_screen_pass = null
