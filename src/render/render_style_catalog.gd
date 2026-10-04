extends RefCounted
class_name RenderStyleCatalog
## What the frame can be styled as: the built-in styles plus every mod-registered
## one, in one deterministic order.
##
## A style *definition* is `{id, display_name, category, factory}` where `factory`
## is `Callable -> RenderStyle`. Mods register through the same seam the core uses
## (`ModContext.add_render_style`), so the director needs no special case for mod
## content — it reads one merged view, exactly like the spawn menu reads props.
##
## This is `PropCatalog`'s shape on purpose. Two catalogs that answer the same
## question the same way are one idea, and it should be possible to learn the
## second by having read the first.

## Built-in styles. `realistic` first: it is the default and the id a save
## without a style falls back to.
static func builtin_entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	out.append({"id": &"realistic", "display_name": "写实", "category": "builtin", "factory": _make_realistic})
	out.append({"id": &"toon", "display_name": "3渲2", "category": "builtin", "factory": _make_toon})
	return out


## Everything the style switch offers: built-ins first, then mod styles.
static func entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = builtin_entries()
	for entry: Variant in ModHost.content_ordered(&"render_style"):
		if entry is Dictionary:
			out.append(entry)
	return out


static func find(style_id: StringName) -> Dictionary:
	for entry: Dictionary in entries():
		if StringName(entry.get("id", &"")) == style_id:
			return entry
	return {}


static func has(style_id: StringName) -> bool:
	return not find(style_id).is_empty()


## Instantiate a style by id, or null when the id is unknown or its factory is
## broken. A mod-supplied factory that returns the wrong type is refused here
## rather than failing later inside the director's apply loop, where the cause
## would be several frames away from the mistake.
static func make(style_id: StringName) -> RenderStyle:
	var entry: Dictionary = find(style_id)
	if entry.is_empty():
		return null
	var factory: Variant = entry.get("factory")
	if not (factory is Callable) or not (factory as Callable).is_valid():
		push_error("[render] style '%s' has no usable factory" % style_id)
		return null
	var produced: Variant = (factory as Callable).call()
	if not (produced is RenderStyle):
		push_error("[render] style '%s' factory did not return a RenderStyle" % style_id)
		return null
	return produced as RenderStyle


static func ids() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for entry: Dictionary in entries():
		out.append(String(entry.get("id", "")))
	return out


static func display_name_of(style_id: StringName) -> String:
	var entry: Dictionary = find(style_id)
	return String(entry.get("display_name", String(style_id)))


static func _make_realistic() -> RenderStyle:
	return RealisticRenderStyle.new()


static func _make_toon() -> RenderStyle:
	return ToonRenderStyle.new()
