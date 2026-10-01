extends RefCounted
class_name PropCatalog
## What the island is made of: the scatterable kinds of prop and their tuning.
##
## Split out of `WorldScatter`, which keeps the placement algorithm. The two are
## genuinely different jobs — this file is data and asset loading, that one is a
## jittered-grid sampler — and they change for different reasons: retuning a forest's
## density or adding a rock model touches only this file.
##
## A mod does not edit this. It registers a factory with `context.add_prop_factory`, and
## `WorldScatter` turns that into an extra kind with the defaults below; the entries here
## are the world's own content.
##
## Determinism contract: nothing here may read the clock or the global RNG. Placement
## derives its variation from `(world seed, kind id, cell)`, so a kind's *parameters*
## are the only thing that decides where it ends up.

## A scatterable kind of prop.
class PropKind:
	var id: StringName
	var mesh: Mesh
	var material: Material
	## Metres between candidate positions; larger is sparser.
	var spacing: float = 18.0
	## Cells to skip, producing gaps instead of a uniform carpet.
	var skip_ratio: float = 0.35
	## Candidates on ground steeper than this are rejected.
	var max_slope_degrees: float = 28.0
	var min_scale: float = 0.8
	var max_scale: float = 1.35
	## Adds a physics body so the player cannot walk through it.
	var collidable: bool = false
	## Also requires a minimum height above sea level.
	var min_height: float = 0.5
	## Biases placement toward the island interior (0 = anywhere on land).
	var interior_bias: float = 0.0
	## Cap on instances, as a safety net for a small map.
	var max_instances: int = 900


## The world's built-in kinds: vegetation first, then rocks. Order is stable, so the
## debug overlay's per-kind counts read the same way every run.
static func core_kinds() -> Array[PropKind]:
	var out: Array[PropKind] = []

	var conifer := PropKind.new()
	conifer.id = &"conifer"
	conifer.mesh = PropFactory.make_conifer(8.5, 1.9)
	conifer.material = PropFactory.make_material(Color(0.24, 0.17, 0.11), Color(0.13, 0.32, 0.17))
	conifer.spacing = 16.0
	conifer.skip_ratio = 0.42
	conifer.max_slope_degrees = 26.0
	conifer.min_scale = 0.8
	conifer.max_scale = 1.5
	conifer.min_height = 2.0
	conifer.interior_bias = 0.2
	conifer.max_instances = 700
	out.append(conifer)

	var broadleaf := PropKind.new()
	broadleaf.id = &"broadleaf"
	broadleaf.mesh = PropFactory.make_broadleaf(6.0, 2.6)
	broadleaf.material = PropFactory.make_material(Color(0.3, 0.21, 0.13), Color(0.22, 0.42, 0.16))
	broadleaf.spacing = 22.0
	broadleaf.skip_ratio = 0.55
	broadleaf.max_slope_degrees = 20.0
	broadleaf.min_scale = 0.85
	broadleaf.max_scale = 1.3
	broadleaf.min_height = 1.0
	broadleaf.max_instances = 420
	out.append(broadleaf)

	var bush := PropKind.new()
	bush.id = &"bush"
	bush.mesh = PropFactory.make_bush(0.9)
	bush.material = PropFactory.make_material(Color(0.2, 0.26, 0.14), Color(0.26, 0.4, 0.18), 0.9)
	bush.spacing = 11.0
	bush.skip_ratio = 0.6
	bush.max_slope_degrees = 34.0
	bush.min_scale = 0.7
	bush.max_scale = 1.5
	bush.max_instances = 700
	out.append(bush)

	var grass := PropKind.new()
	grass.id = &"grass"
	grass.mesh = PropFactory.make_grass_tuft(0.7)
	grass.material = PropFactory.make_material(Color(0.32, 0.42, 0.18), Color(0.4, 0.52, 0.2), 0.95)
	grass.spacing = 4.5
	grass.skip_ratio = 0.35
	grass.max_slope_degrees = 32.0
	grass.min_scale = 0.7
	grass.max_scale = 1.6
	grass.max_instances = 2600
	out.append(grass)

	out.append_array(rock_kinds())
	return out


## The CC0 rock models from the Terrain3D asset pack, wrapped as scatterables.
##
## One kind per mesh found, so a model with several primitives scatters as several
## kinds rather than losing all but the first. A missing asset pack downgrades the world
## to vegetation instead of failing generation — rocks are decoration, and a project
## without the models should still boot.
static func rock_kinds() -> Array[PropKind]:
	var out: Array[PropKind] = []
	var models: Array[String] = [
		"res://assets/props/RockA.glb",
		"res://assets/props/RockB.glb",
		"res://assets/props/RockC.glb",
	]
	var loaded: int = 0
	for model_path: String in models:
		var meshes: Array[Mesh] = PropFactory.load_model_meshes(model_path)
		for mesh: Mesh in meshes:
			var kind := PropKind.new()
			kind.id = StringName("rock_%d" % loaded)
			kind.mesh = mesh
			kind.material = PropFactory.make_material(Color(0.42, 0.42, 0.44), Color(0.5, 0.5, 0.52), 0.9)
			kind.spacing = 30.0
			kind.skip_ratio = 0.55
			kind.max_slope_degrees = 42.0
			kind.min_scale = 0.9
			kind.max_scale = 2.6
			kind.collidable = true
			kind.min_height = -1.0
			kind.max_instances = 160
			out.append(kind)
			loaded += 1
	if loaded == 0:
		push_warning("PropCatalog: no rock models found under assets/props; scattering vegetation only")
	return out
