extends RenderStyle
class_name PresetRenderStyle
## A style that is nothing but a set of `DemoLook` overrides.
##
## This exists because it is the shape a mod actually wants. "黄金时刻", "阴天",
## "黑白", "赛博霓虹" are all colour-and-light opinions about the map's authored
## look, and expressing them should cost a dictionary — not a subclass, not a
## shader, and not a copy of the environment stage.
##
## A style that needs a screen-space pass or a material swap still writes a
## `RenderStyle` subclass (see `ToonRenderStyle`); the important part is that the
## cheap case is genuinely cheap, so the seam gets used instead of worked around.

var _id: StringName
var _name: String
var _overrides: Dictionary


func _init(style_id: StringName = &"", display_name: String = "", overrides: Dictionary = {}) -> void:
	_id = style_id
	_name = String(display_name)
	# Deep copy: the caller's dictionary is usually a literal in a mod's
	# registration call, and a style that mutates its own definition would make
	# "switch away and back" stop being the same look twice.
	_overrides = overrides.duplicate(true)


func style_id() -> StringName:
	return _id


func display_name() -> String:
	return _name if not _name.is_empty() else String(_id)


func describe() -> String:
	return "%s (%d 项覆盖)" % [display_name(), _overrides.size()]


## The deviations this style applies, read-only in spirit — returns a copy so a
## caller cannot reach in and edit the definition the catalog handed out.
func overrides() -> Dictionary:
	return _overrides.duplicate(true)


func apply(context: Dictionary) -> bool:
	return retune(context, _overrides)
