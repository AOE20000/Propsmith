extends Node
## Service container: the single seam every module resolves its collaborators
## through, so features can be added, replaced, or removed without editing each
## other. Autoloaded as `Services`.
##
## Registration is explicit and ordered: a provider registers in `_ready()` and
## consumers look the service up lazily, never at parse time.

var _services: Dictionary = {}
var _registration_order: PackedStringArray = []
## `class_name` -> its script, or null when unresolvable. See
## `_script_for_global_class`.
var _global_class_scripts: Dictionary = {}

## Emitted whenever the service set changes, so UI can refresh capability lists.
signal service_registered(service_name: StringName)
signal service_unregistered(service_name: StringName)


## Register a service under a stable name. Re-registering without `replace`
## is an error: a silent overwrite hides double-initialization bugs.
func register(service_name: StringName, instance: Variant, replace: bool = false) -> void:
	if service_name == &"":
		push_error("Services.register: empty service name")
		return
	if instance == null:
		push_error("Services.register: null instance for '%s'" % service_name)
		return
	if not replace and _services.has(service_name):
		push_error("Services.register: '%s' is already registered (pass replace=true to override)" % service_name)
		return
	if not _services.has(service_name):
		_registration_order.append(String(service_name))
	_services[service_name] = instance
	service_registered.emit(service_name)


## Remove a service; returns whether it existed.
func unregister(service_name: StringName) -> bool:
	if not _services.has(service_name):
		return false
	_services.erase(service_name)
	_registration_order.erase(String(service_name))
	service_unregistered.emit(service_name)
	return true


func has(service_name: StringName) -> bool:
	return _services.has(service_name)


## Resolve a service, or null when nothing provides it. Callers must handle
## null: a missing optional module is a supported configuration, not a crash.
func get_service(service_name: StringName) -> Variant:
	return _services.get(service_name)


## Resolve a service and fail loudly when it is absent, for hard dependencies.
func require(service_name: StringName) -> Variant:
	var instance: Variant = _services.get(service_name)
	if instance == null:
		push_error("Services.require: '%s' is not registered" % service_name)
	return instance


## Resolve a service onto a typed local, returning null when it is absent or
## carries an unexpected type.
##
## `Object.is_class()` only recognises native engine classes, so a `class_name`
## script would always fail that test. This resolves the global class to its script
## and walks the instance's own script chain, falling back to `is_class` for a
## built-in type.
func get_as(service_name: StringName, expected_class: StringName) -> Variant:
	var instance: Variant = _services.get(service_name)
	if instance == null:
		return null
	if not (instance is Object):
		push_warning("Services.get_as: '%s' is not an Object" % service_name)
		return null
	var object: Object = instance
	var expected_script: GDScript = _script_for_global_class(expected_class)
	if expected_script != null and _inherits_script(object, expected_script):
		return object
	if expected_script == null and object.is_class(expected_class):
		return object
	push_warning("Services.get_as: '%s' is not a %s" % [service_name, expected_class])
	return null


## Whether the object's script is, or extends, `expected_script`.
func _inherits_script(object: Object, expected_script: GDScript) -> bool:
	var script: Script = object.get_script() as Script
	while script != null:
		if script == expected_script:
			return true
		script = script.get_base_script()
	return false


## Look up the script behind a global class name, memoised.
##
## Memoised because the project's global class list is fixed once the project loads —
## no script can introduce a `class_name` at runtime — while `get_as()` is called from
## the debug overlay every frame and from code that runs per mod call. Re-deriving the
## list and re-loading the script on each call was pure overhead. A name that resolves
## to nothing is cached too, so a repeatedly-asked-for missing class is not re-scanned
## either.
func _script_for_global_class(class_name_value: StringName) -> GDScript:
	if _global_class_scripts.has(class_name_value):
		return _global_class_scripts[class_name_value] as GDScript
	var resolved: GDScript = _resolve_global_class(class_name_value)
	_global_class_scripts[class_name_value] = resolved
	return resolved


func _resolve_global_class(class_name_value: StringName) -> GDScript:
	var registered: Array[Dictionary] = ProjectSettings.get_global_class_list()
	for entry: Dictionary in registered:
		if StringName(String(entry.get("class", ""))) != class_name_value:
			continue
		# "GDScript" marks a script class; anything else is a native base and is
		# handled by the `is_class` fallback in the caller.
		if String(entry.get("language", "GDScript")) != "GDScript":
			return null
		var path: String = String(entry.get("path", ""))
		if path.is_empty() or not ResourceLoader.exists(path):
			return null
		return load(path) as GDScript
	return null


func names() -> PackedStringArray:
	return _registration_order.duplicate()


## Diagnostic snapshot for the debug overlay.
func describe() -> Array[String]:
	var lines: Array[String] = []
	for service_name: String in _registration_order:
		lines.append("%s -> %s" % [service_name, _services[service_name]])
	return lines


func clear() -> void:
	for service_name: String in _registration_order.duplicate():
		unregister(StringName(service_name))
