extends Resource
class_name TerrainConfig
## Tunable shape of the island. Kept as a Resource so a mod or a designer can
## ship an alternative world shape without touching the generator.

## Deterministic seed for every noise layer.
@export var seed: int = 20260930
## Terrain3D region size; a power of two dividing the island extent well.
@export_enum("64", "128", "256", "512") var region_size: int = 256
## Metres between terrain vertices.
@export_range(0.5, 4.0, 0.25) var vertex_spacing: float = 1.0
## Radius of the landmass in metres.
@export_range(64.0, 2048.0, 16.0) var island_radius: float = 420.0
## How sharply the coast falls away; higher is steeper.
@export_range(0.5, 4.0, 0.05) var island_falloff: float = 1.35
## Highest land above sea level, in metres.
@export_range(8.0, 200.0, 1.0) var max_height: float = 48.0
## Controls the large-scale landmass shape.
@export_range(0.0, 1.0, 0.01) var continent_weight: float = 0.62
## Rolling hills on top of the landmass.
@export_range(0.0, 1.0, 0.01) var hill_weight: float = 0.28
## Ridged mountain spines. Keep low for a walkable small world.
@export_range(0.0, 1.0, 0.01) var mountain_weight: float = 0.10
## Pushes low ground flatter and keeps peaks sharp.
@export_range(0.5, 3.0, 0.05) var height_curve: float = 1.25
## Metres of sampling step for the CPU heightfield used by queries and scatter.
@export_range(1.0, 8.0, 0.5) var sample_step: float = 2.0
## Region-granular radius of playable land; derived from island_radius.
@export var spawn_search_radius: float = 120.0


## Number of Terrain3D regions per axis needed to cover the island plus a margin.
func regions_per_axis() -> int:
	var covered: float = island_radius * 2.0 + float(region_size) * 2.0
	return int(ceil(covered / float(region_size)))


func to_terrain_query(query: TerrainQuery) -> void:
	query.island_radius = island_radius
	query.island_falloff_curve = island_falloff
	query.max_height = max_height
