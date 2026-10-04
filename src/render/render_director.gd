extends Node
class_name RenderDirector
## Owns the frame's active render style: which one is applied, and switching it.
##
## Registered as the `render_style` service. A node rather than a plain service
## object because two things in the contract need a lifetime: styles parent their
## passes to the director (so a pass outlives the world), and the director must
## outlive a map reload — every `map_source.build()` replaces the
## `WorldEnvironment`, so the director re-applies the active style on
## `Events.world_ready` instead of assuming the handles it was given stay valid.
##
## Switching is a release-then-apply pair, and the failure path matters more than
## the happy one: a style that cannot apply must not leave the frame half-styled,
## so the director falls back to the reset style rather than to nothing.

## The style a session starts on, and the one a failed switch falls back to.
const DEFAULT_STYLE: StringName = &"realistic"

var _active_id: StringName = DEFAULT_STYLE
var _active: RenderStyle = null
var _world: Node3D = null


func _ready() -> void:
	Events.world_ready.connect(_on_world_ready)
	Events.world_teardown_started.connect(_on_world_teardown)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"cycle_render_style"):
		cycle(1)
		get_viewport().set_input_as_handled()


## Every style on offer, in switch order: built-ins then mods.
func available() -> Array[Dictionary]:
	return RenderStyleCatalog.entries()


func current_id() -> StringName:
	return _active_id


func current_display_name() -> String:
	return RenderStyleCatalog.display_name_of(_active_id)


## Apply `style_id`. Returns false only when the id is unknown — the request is
## accepted before the world exists, and lands when the world does. A style that
## is known but cannot apply falls back to `DEFAULT_STYLE` and still reports true,
## because "the frame is styled" is what the caller is asking about.
func set_style(style_id: StringName) -> bool:
	if not RenderStyleCatalog.has(style_id):
		push_warning("[render] no render style '%s' — keeping '%s'" % [style_id, _active_id])
		return false
	_active_id = style_id
	if not _apply_current() and style_id != DEFAULT_STYLE:
		push_warning("[render] style '%s' could not be applied; falling back to '%s'" % [style_id, DEFAULT_STYLE])
		_active_id = DEFAULT_STYLE
		_apply_current()
	_announce()
	return true


## Step through the catalogue, wrapping. `step` may be negative.
func cycle(step: int = 1) -> bool:
	var ids: PackedStringArray = RenderStyleCatalog.ids()
	if ids.is_empty():
		return false
	var index: int = ids.find(String(_active_id))
	index = 0 if index < 0 else posmod(index + step, ids.size())
	return set_style(StringName(ids[index]))


func describe() -> String:
	var names: PackedStringArray = PackedStringArray()
	for entry: Dictionary in available():
		names.append(String(entry.get("id", "")))
	return "%s / %s — %d 种 [%s]" % [
		_active_id, current_display_name(), names.size(), ", ".join(names),
	]


## The world was (re)built under us. Re-apply the current style: the environment
## this style retuned a moment ago no longer exists. Silent on purpose — this is
## a restore of state every listener already knows, and a "画风：写实" toast on
## every map load would be noise about nothing having happened.
func _on_world_ready(world: Node3D) -> void:
	_world = world
	if not _apply_current():
		_active_id = DEFAULT_STYLE
		_apply_current()


## The world is going away; the style's passes are not part of it. Left applied,
## a screen-space pass would survive the reload and stack with the next one.
func _on_world_teardown() -> void:
	_release_active()
	_world = null


## Release whatever is on the frame and put `_active_id` on it. Idempotent, and
## the only place a style is ever instantiated.
func _apply_current() -> bool:
	_release_active()
	if _world == null or not is_instance_valid(_world):
		return false
	var style: RenderStyle = RenderStyleCatalog.make(_active_id)
	if style == null:
		return false
	_active = style
	if not style.apply(_context()):
		_active = null
		return false
	return true


func _release_active() -> void:
	if _active != null:
		_active.release()
		_active = null


func _context() -> Dictionary:
	return {
		"world": _world,
		"environment": _find(_world, "WorldEnvironment") as WorldEnvironment,
		"sun": _find(_world, "DirectionalLight3D") as DirectionalLight3D,
		"host": self,
		"viewport": get_viewport(),
	}


## First node of a native class anywhere under `root`.
##
## `owned = false` because every node in this project is built in code and so has
## no `owner`; the default would find nothing at all and every style would report
## "no environment to retune", pointing at the wrong module entirely.
func _find(root: Node3D, type_name: String) -> Node:
	if root == null or not is_instance_valid(root):
		return null
	var found: Array[Node] = root.find_children("*", type_name, true, false)
	return found[0] if not found.is_empty() else null


func _announce() -> void:
	var label: String = current_display_name()
	Events.render_style_changed.emit(_active_id, label)
	Events.notify("画风：%s" % label, Events.NotifyLevel.SUCCESS)
