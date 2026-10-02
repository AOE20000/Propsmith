extends Node
## Save/load of a textual JSON document under `user://saves`, autoloaded as
## `SaveSystem`.
##
## Deliberately not `ResourceSaver`: a save file must survive refactors, so it
## stores plain data with an explicit version and never a script path. Modules
## contribute their own section through `GameState.module_state`, which means a
## module can be deleted without invalidating existing saves.

const SAVE_DIR: String = "user://saves"
const SAVE_EXTENSION: String = ".json"
const DEFAULT_SLOT: String = "slot1"

## Registered providers: `owner_id -> Callable() -> Dictionary`.
var _serializers: Dictionary = {}
## Registered restorers: `owner_id -> Callable(Dictionary) -> void`.
var _deserializers: Dictionary = {}

var last_error: String = ""


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)


## A module registers both halves of its persistence in one call, so it can
## never save state it cannot restore.
func register_persistent(owner_id: StringName, serializer: Callable, deserializer: Callable) -> void:
	_serializers[String(owner_id)] = serializer
	_deserializers[String(owner_id)] = deserializer


func unregister_persistent(owner_id: StringName) -> void:
	_serializers.erase(String(owner_id))
	_deserializers.erase(String(owner_id))


func slot_path(slot: String = DEFAULT_SLOT) -> String:
	return "%s/%s%s" % [SAVE_DIR, slot, SAVE_EXTENSION]


func has_save(slot: String = DEFAULT_SLOT) -> bool:
	return FileAccess.file_exists(slot_path(slot))


func list_slots() -> PackedStringArray:
	var slots: PackedStringArray = []
	var dir: DirAccess = DirAccess.open(SAVE_DIR)
	if dir == null:
		return slots
	for file_name: String in dir.get_files():
		if file_name.ends_with(SAVE_EXTENSION):
			slots.append(file_name.trim_suffix(SAVE_EXTENSION))
	slots.sort()
	return slots


func save_game(slot: String = DEFAULT_SLOT) -> bool:
	last_error = ""
	var payload: Dictionary = {
		"meta": {
			"saved_at_unix": Time.get_unix_time_from_system(),
			"saved_at_text": Time.get_datetime_string_from_system(false, true),
			"engine_version": Engine.get_version_info().get("string", ""),
		},
		"state": GameState.to_dict(),
		"sections": {},
	}

	for owner_id: String in _serializers:
		var serializer: Callable = _serializers[owner_id]
		if not serializer.is_valid():
			continue
		var section: Variant = serializer.call()
		if section is Dictionary:
			(payload["sections"] as Dictionary)[owner_id] = section

	var file: FileAccess = FileAccess.open(slot_path(slot), FileAccess.WRITE)
	if file == null:
		last_error = "cannot open %s for writing (error %d)" % [slot_path(slot), FileAccess.get_open_error()]
		push_error("SaveSystem: " + last_error)
		return false
	file.store_string(JSON.stringify(payload, "  "))
	file.close()

	Events.game_saved.emit(slot)
	Events.notify("已保存到存档位 %s" % slot, Events.NotifyLevel.SUCCESS)
	return true


func load_game(slot: String = DEFAULT_SLOT) -> bool:
	last_error = ""
	if not has_save(slot):
		last_error = "no save in slot %s" % slot
		return false

	var file: FileAccess = FileAccess.open(slot_path(slot), FileAccess.READ)
	if file == null:
		last_error = "cannot read %s" % slot_path(slot)
		push_error("SaveSystem: " + last_error)
		return false
	var text: String = file.get_as_text()
	file.close()

	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		last_error = "save file is not valid JSON"
		push_error("SaveSystem: " + last_error)
		return false

	var payload: Dictionary = parsed
	var state: Variant = payload.get("state", {})
	if not (state is Dictionary):
		last_error = "save file has no readable state"
		return false

	# Map identity is checked before anything is applied: a save made in another
	# city (or on the removed island, whose saves carry no map id at all) must be
	# refused outright, because its places, discoveries and routes all point into
	# a world that is not the one running.
	var saved_map_id: String = String((state as Dictionary).get("map_id", ""))
	var running_map_id: String = GameState.map_id
	if saved_map_id != running_map_id:
		last_error = "存档属于其他地图（存档：%s，当前：%s）— 拒绝读取" % [saved_map_id, running_map_id]
		push_error("SaveSystem: " + last_error)
		return false

	GameState.from_dict(state)

	var sections: Variant = payload.get("sections", {})
	if sections is Dictionary:
		for owner_id: String in (sections as Dictionary):
			if not _deserializers.has(owner_id):
				# A section whose owner is gone is expected after removing a mod.
				continue
			var deserializer: Callable = _deserializers[owner_id]
			if deserializer.is_valid():
				deserializer.call((sections as Dictionary)[owner_id])

	Events.game_loaded.emit(slot)
	Events.notify("已读取存档位 %s" % slot, Events.NotifyLevel.SUCCESS)
	return true


func delete_save(slot: String = DEFAULT_SLOT) -> bool:
	if not has_save(slot):
		return false
	return DirAccess.remove_absolute(ProjectSettings.globalize_path(slot_path(slot))) == OK


## JSON has no vector types, so containers are tagged on the way out and rebuilt
## on the way in. Unknown tags round-trip as-is rather than dropping data.
static func encode_variant(value: Variant) -> Variant:
	if value is Vector3:
		var v3: Vector3 = value
		return {"__type": "Vector3", "x": v3.x, "y": v3.y, "z": v3.z}
	if value is Vector2:
		var v2: Vector2 = value
		return {"__type": "Vector2", "x": v2.x, "y": v2.y}
	if value is Color:
		var c: Color = value
		return {"__type": "Color", "r": c.r, "g": c.g, "b": c.b, "a": c.a}
	if value is Array:
		var out_array: Array = []
		for element: Variant in value:
			out_array.append(encode_variant(element))
		return out_array
	if value is Dictionary:
		var out_dict: Dictionary = {}
		for key: Variant in value:
			out_dict[str(key)] = encode_variant(value[key])
		return out_dict
	return value


static func decode_variant(value: Variant) -> Variant:
	if value is Array:
		var out_array: Array = []
		for element: Variant in value:
			out_array.append(decode_variant(element))
		return out_array
	if value is Dictionary:
		var source: Dictionary = value
		var tag: Variant = source.get("__type", null)
		if tag == "Vector3":
			return Vector3(float(source.get("x", 0.0)), float(source.get("y", 0.0)), float(source.get("z", 0.0)))
		if tag == "Vector2":
			return Vector2(float(source.get("x", 0.0)), float(source.get("y", 0.0)))
		if tag == "Color":
			return Color(
				float(source.get("r", 1.0)), float(source.get("g", 1.0)),
				float(source.get("b", 1.0)), float(source.get("a", 1.0))
			)
		var out_dict: Dictionary = {}
		for key: Variant in source:
			out_dict[key] = decode_variant(source[key])
		return out_dict
	return value
