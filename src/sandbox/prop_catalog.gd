extends RefCounted
class_name PropCatalog
## The list of props the spawn menu offers: the built-in catalogue plus every
## mod-registered prop, in one deterministic order.
##
## A prop *definition* is `{id, display_name, factory, category, owner}` where
## `factory` is `Callable -> RigidBody3D`. Mods register through the same seam
## the core uses (`ModContext.add_prop_factory`), so the menu needs no special
## case for mod content — it reads one merged view.

## Built-in props. Small, boring, and enough to build with: something to stack,
## something to roll, something to lean, something heavy. Named static builders
## rather than inline lambdas — GDScript parses those inside dictionary
## literals reluctantly, and a prop list should never be a syntax puzzle.
static func builtin_entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	out.append({"id": &"crate", "display_name": "木箱", "category": "basic", "factory": _make_crate})
	out.append({"id": &"barrel", "display_name": "圆桶", "category": "basic", "factory": _make_barrel})
	out.append({"id": &"ball", "display_name": "弹力球", "category": "basic", "factory": _make_ball})
	out.append({"id": &"plank", "display_name": "木板", "category": "basic", "factory": _make_plank})
	out.append({"id": &"ramp", "display_name": "斜坡", "category": "basic", "factory": _make_ramp})
	out.append({"id": &"block", "display_name": "混凝土块", "category": "heavy", "factory": _make_block})
	return out


## Everything the spawn menu shows: built-ins first, then mod props.
static func entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = builtin_entries()
	for entry: Variant in ModHost.content_ordered(&"prop"):
		if entry is Dictionary:
			out.append(entry)
	return out


## Look up one definition by id, across built-ins and mods.
static func find(prop_id: StringName) -> Dictionary:
	for entry: Dictionary in entries():
		if StringName(entry.get("id", &"")) == prop_id:
			return entry
	return {}


static func _make_crate() -> RigidBody3D:
	return PropFactory.build_box(Vector3(0.8, 0.8, 0.8), Color(0.62, 0.47, 0.30), 20.0)


static func _make_barrel() -> RigidBody3D:
	return PropFactory.build_cylinder(0.35, 0.9, Color(0.35, 0.42, 0.5), 15.0)


static func _make_ball() -> RigidBody3D:
	return PropFactory.build_ball(0.3, Color(0.82, 0.3, 0.26), 5.0, 0.65)


static func _make_plank() -> RigidBody3D:
	return PropFactory.build_box(Vector3(2.4, 0.1, 0.6), Color(0.72, 0.58, 0.40), 8.0)


static func _make_ramp() -> RigidBody3D:
	return PropFactory.build_ramp(1.6, 2.4, 0.2, Color(0.66, 0.66, 0.62), 22.0)


static func _make_block() -> RigidBody3D:
	return PropFactory.build_box(Vector3(1.0, 1.0, 1.0), Color(0.55, 0.55, 0.54), 400.0)
