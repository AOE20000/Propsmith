extends SandboxTool
class_name CallbackTool
## A `SandboxTool` whose behaviour is supplied as callables — the shape both a
## scripted mod and a quick GDScript prototype find easiest, since neither has
## to declare a class to get a tool into the gun.
##
## Invalid or missing callbacks simply do nothing, which keeps a half-written
## tool from crashing the gun that holds it. Lives beside the other sandbox
## classes: `ModContext` wraps these, and `ScriptBridge` hands them to
## foreign-language mods — a separate file keeps that wiring free of
## class-name cycles.

var _callbacks: Dictionary = {}


func _init(id: StringName = &"", name: String = "", callbacks: Dictionary = {}) -> void:
	super._init(id, name)
	_callbacks = callbacks


func selected() -> void:
	_fire("selected")


func deselected() -> void:
	_fire("deselected")


func on_primary(hit: Dictionary) -> void:
	_fire("on_primary", [hit])


func on_secondary(hit: Dictionary) -> void:
	_fire("on_secondary", [hit])


func _fire(key: String, args: Array = []) -> void:
	var callback: Variant = _callbacks.get(key)
	if callback is Callable and (callback as Callable).is_valid():
		(callback as Callable).callv(args)
