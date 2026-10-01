extends Node
## Session-wide mutable state that is worth saving, autoloaded as `GameState`.
##
## Anything a module can recompute (terrain, prop placement, UI) stays out of
## here. Only decisions and discoveries live here, which keeps the save file
## small and keeps world generation deterministic from `world_seed` alone.

enum Mode { BOOT, EXPLORING, PAUSED, MAP, DEAD }

const SAVE_VERSION: int = 1

var mode: Mode = Mode.BOOT:
	set(value):
		if mode == value:
			return
		var previous: Mode = mode
		mode = value
		Events.game_mode_changed.emit(int(previous), int(value))

## Seed for all deterministic world generation. Changing it produces a different
## island with the same size and rules.
var world_seed: int = 20260930

var play_time_seconds: float = 0.0
var total_distance_travelled: float = 0.0

## Discovery and collection progress, keyed for stable saves.
var discovered_pois: Dictionary = {}
var collected_items: Dictionary = {}
var visited_regions: Dictionary = {}

## Spawn point used by respawn and by "return to start".
var spawn_position: Vector3 = Vector3.ZERO
var has_spawn_position: bool = false

## Extension bag: modules and mods keep their own serializable state here under
## their own key, so core never needs to know about a feature to save it.
var module_state: Dictionary = {}


func _process(delta: float) -> void:
	if mode == Mode.EXPLORING:
		play_time_seconds += delta


func reset_for_new_world(new_seed: int = -1) -> void:
	if new_seed >= 0:
		world_seed = new_seed
	play_time_seconds = 0.0
	total_distance_travelled = 0.0
	discovered_pois.clear()
	collected_items.clear()
	visited_regions.clear()
	module_state.clear()
	has_spawn_position = false
	spawn_position = Vector3.ZERO


func set_spawn(world_position: Vector3) -> void:
	spawn_position = world_position
	has_spawn_position = true


func is_poi_discovered(poi_id: StringName) -> bool:
	return discovered_pois.has(String(poi_id))


## Returns true only the first time a POI is discovered, so callers can gate the
## one-shot reward and notification on it.
func mark_poi_discovered(poi_id: StringName) -> bool:
	var key: String = String(poi_id)
	if discovered_pois.has(key):
		return false
	discovered_pois[key] = true
	return true


func mark_collected(item_id: StringName, amount: int = 1) -> void:
	var key: String = String(item_id)
	collected_items[key] = int(collected_items.get(key, 0)) + amount


func collected_count(item_id: StringName) -> int:
	return int(collected_items.get(String(item_id), 0))


func mark_region_visited(region_id: StringName) -> bool:
	var key: String = String(region_id)
	if visited_regions.has(key):
		return false
	visited_regions[key] = true
	return true


## Per-module persistence slot. Modules call this instead of adding fields here.
func get_module_state(owner_id: StringName) -> Dictionary:
	var key: String = String(owner_id)
	if not module_state.has(key):
		module_state[key] = {}
	return module_state[key] as Dictionary


func to_dict() -> Dictionary:
	return {
		"save_version": SAVE_VERSION,
		"world_seed": world_seed,
		"play_time_seconds": play_time_seconds,
		"total_distance_travelled": total_distance_travelled,
		"discovered_pois": discovered_pois.duplicate(true),
		"collected_items": collected_items.duplicate(true),
		"visited_regions": visited_regions.duplicate(true),
		"spawn_position": SaveSystem.encode_variant(spawn_position),
		"has_spawn_position": has_spawn_position,
		"module_state": module_state.duplicate(true),
	}


func from_dict(data: Dictionary) -> void:
	world_seed = int(data.get("world_seed", world_seed))
	play_time_seconds = float(data.get("play_time_seconds", 0.0))
	total_distance_travelled = float(data.get("total_distance_travelled", 0.0))
	discovered_pois = (data.get("discovered_pois", {}) as Dictionary).duplicate(true)
	collected_items = (data.get("collected_items", {}) as Dictionary).duplicate(true)
	visited_regions = (data.get("visited_regions", {}) as Dictionary).duplicate(true)
	spawn_position = SaveSystem.decode_variant(data.get("spawn_position", null)) as Vector3
	has_spawn_position = bool(data.get("has_spawn_position", false))
	module_state = (data.get("module_state", {}) as Dictionary).duplicate(true)


func format_play_time() -> String:
	var total: int = int(play_time_seconds)
	return "%02d:%02d:%02d" % [total / 3600, (total / 60) % 60, total % 60]
