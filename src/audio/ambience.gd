extends Node
class_name Ambience
## The ambience mix: a crossfaded bed, plus whatever point sources a map hangs on
## it.
##
## Registered as the `ambience` service. It owns *the mix* — one bus, one bed at a
## time, one crossfade — and nothing about any particular map. Which bed a map
## wants, and where its water is, are the map's own facts, declared through
## `set_beds` and `attach_point`. That is the same split as the `DemoLook` presets,
## for the same reason: a module with "the pond is at z=60" inside it is a second
## copy of the ground plan, and the two copies would drift.
##
## ## The beds follow the light
##
## A session that switches to dusk should not keep hearing midday, so the beds
## subscribe to `Events.look_preset_changed` and crossfade. The mapping from preset
## to bed belongs to the map: a city at dusk still sounds like a city, and says so
## by not listing a `dusk` bed at all and letting the fallback carry it.
##
## ## Why two players and not one
##
## A crossfade needs both ends audible at once, and a single player cannot fade out
## what it has already replaced. Two players, swapped, is the whole mechanism.
##
## ## Levels are measured, not chosen by ear
##
## The shipped beds differ by up to 13 dB in average level (see `BED_LEVELS`), so
## playing them at one gain would make the ambience jump every time the sky
## changed. Each stream is normalised to a common average — the same trick as
## normalising a music library — and the numbers come from `ffmpeg -af
## volumedetect` on the files in `assets/audio/`, not from a taste judgement
## nobody can reproduce.

## One runtime bus for the whole ambience layer, so a settings screen can find it
## without asking this module for a handle. Created rather than shipped as a
## bus-layout resource to keep the module a single file.
const BUS_NAME: StringName = &"Ambience"

## Average level the beds are normalised to. Background level on purpose: this is a
## bed under the world, not a feature.
const BED_TARGET_DB: float = -32.0

## dB at which a player is treated as inaudible. Not `-INF`: a tween interpolates
## linearly, and a linear ramp towards negative infinity never arrives.
const SILENT_DB: float = -60.0

## Default crossfade. Long enough to read as a change of light rather than a cut.
const CROSSFADE_SECONDS: float = 2.0

## Measured average levels of the shipped beds, in dBFS, from
## `ffmpeg -i <file> -af volumedetect -f null -`.
##
## Keyed by resource path because the number is a property of the *asset*, and the
## asset is where a reader should be able to disagree with it. A stream that is not
## listed is played at its own level, which is the honest default for a mod's
## material this module has never measured.
const BED_LEVELS: Dictionary = {
	"res://assets/audio/ambience_forest.ogg": -24.2,
	"res://assets/audio/ambience_night.ogg": -26.8,
	"res://assets/audio/ambience_city.ogg": -37.3,
	"res://assets/audio/water_stream.ogg": -21.6,
}

## preset id -> stream, as handed over by the map; `&"default"` is the fallback.
var _beds: Dictionary = {}
var _bed_players: Array[AudioStreamPlayer] = []
var _active: int = 0
var _preset: StringName = &""
## Point sources a map hung on the mix, kept so teardown can silence them.
var _points: Array[AudioStreamPlayer3D] = []


## Whether there is anywhere for sound to come out.
##
## In `--headless` the audio driver is a dummy that answers every `play()` with
## `ERROR: Failed to instantiate playback.` — an engine *error* for a condition this
## module can see coming. Whitelisting that line in the CI runner would have been
## the easy route and the wrong one: the same message is what a broken sound device
## produces, so the whitelist would hide a real fault to silence a known
## non-event. Not starting playback is the honest fix — the streams, their loops
## and their levels are all still built and assertable.
static func _can_play() -> bool:
	return DisplayServer.get_name() != "headless"


func _ready() -> void:
	_ensure_bus()
	for index: int in 2:
		var player := AudioStreamPlayer.new()
		player.name = "Bed%d" % index
		player.bus = BUS_NAME
		player.volume_db = SILENT_DB
		add_child(player)
		_bed_players.append(player)
	Events.look_preset_changed.connect(_on_preset_changed)
	Events.world_teardown_started.connect(_on_world_teardown)


## Declare which bed this map wants for which preset, and start on `preset`.
##
## `beds` maps a preset id to an `AudioStream`; the key `&"default"` is used for
## any preset the map did not list. An empty dictionary is legal and means "this
## map has no ambience", which is the honest answer for a map whose city bed does
## not exist yet — better than a forest playing in a shopping district.
## `fade_seconds` of 0 applies instantly, which is what a test wants and what a
## map that is being rebuilt from a save should probably want too.
func set_beds(beds: Dictionary, preset: StringName, fade_seconds: float = CROSSFADE_SECONDS) -> void:
	_beds = beds.duplicate()
	_preset = preset
	# Faded in rather than started at level: this runs as the world becomes
	# visible, and a bed that simply appears reads as a glitch.
	_crossfade(_stream_for(preset), fade_seconds)


func beds_declared() -> int:
	return _beds.size()


## Hang a looping point source on the mix — the pond, a fountain, a machine. The
## player is owned here so its lifetime follows the world rather than the map's
## node count, and it is parented to the service because the map's own nodes are
## about to be freed.
func attach_point(
	stream: AudioStream,
	at: Vector3,
	radius: float = 40.0,
	unit: float = 8.0,
) -> AudioStreamPlayer3D:
	if stream == null:
		return null
	var player := AudioStreamPlayer3D.new()
	player.name = "Point"
	player.bus = BUS_NAME
	player.stream = _looping(stream)
	player.volume_db = _normalised_gain(stream)
	player.max_distance = radius
	player.unit_size = unit
	player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	add_child(player)
	# After `add_child`, or the position is applied to a node outside the tree and
	# silently overwritten when it enters one.
	player.global_position = at
	if _can_play():
		player.play()
	_points.append(player)
	return player


## The whole ambience layer's level, for a settings slider. Separate from the
## master so ambience can be turned down without silencing the game.
func set_volume_db(db: float) -> void:
	var index: int = AudioServer.get_bus_index(BUS_NAME)
	if index >= 0:
		AudioServer.set_bus_volume_db(index, db)


func volume_db() -> float:
	var index: int = AudioServer.get_bus_index(BUS_NAME)
	return AudioServer.get_bus_volume_db(index) if index >= 0 else 0.0


func describe() -> String:
	if _beds.is_empty():
		return "无（地图未声明）"
	var names: PackedStringArray = PackedStringArray()
	for key: Variant in _beds:
		names.append(String(key))
	return "%s · %d 个床 [%s] · %d 个点声源 · 总线 %s（%s）" % [
		_preset if not _preset.is_empty() else "—",
		_beds.size(), ", ".join(names), _points.size(),
		BUS_NAME, AudioServer.get_driver_name(),
	]


func _on_preset_changed(preset_id: StringName, _label: String) -> void:
	_preset = preset_id
	if _beds.is_empty():
		return
	_crossfade(_stream_for(preset_id), CROSSFADE_SECONDS)


## The world is going away, and the point sources hung on it with it.
func _on_world_teardown() -> void:
	for player: AudioStreamPlayer3D in _points:
		if is_instance_valid(player):
			player.queue_free()
	_points.clear()
	for player: AudioStreamPlayer in _bed_players:
		player.stop()
		player.volume_db = SILENT_DB
	_beds.clear()


func _stream_for(preset: StringName) -> AudioStream:
	if _beds.has(preset):
		return _beds[preset] as AudioStream
	return _beds.get(&"default", null) as AudioStream


## Bring `stream` up while taking the current bed down. A null stream fades to
## silence and leaves it there — a map with no `default` bed is silent, not stuck
## on the last one.
func _crossfade(stream: AudioStream, seconds: float) -> void:
	var outgoing: AudioStreamPlayer = _bed_players[_active]
	# Already playing this one: a preset change that maps to the same bed (say
	# city -> day, both the city bed) should not restart it.
	if stream != null and outgoing.stream == stream and outgoing.playing:
		return
	var incoming: AudioStreamPlayer = _bed_players[1 - _active]
	_active = 1 - _active

	if seconds <= 0.0:
		outgoing.stop()
		outgoing.volume_db = SILENT_DB
		if stream != null:
			incoming.stream = _looping(stream)
			incoming.volume_db = _normalised_gain(stream)
			if _can_play():
				incoming.play()
		return

	incoming.stream = _looping(stream) if stream != null else null
	if stream != null:
		incoming.volume_db = SILENT_DB
		if _can_play():
			incoming.play()
	var target: float = _normalised_gain(stream) if stream != null else SILENT_DB
	var tween := create_tween().set_parallel(true)
	tween.tween_property(incoming, "volume_db", target, seconds)
	tween.tween_property(outgoing, "volume_db", SILENT_DB, seconds)
	tween.finished.connect(func() -> void:
		if is_instance_valid(outgoing):
			outgoing.stop()
	)


## Turn a stream into a loop, once, on the shared resource.
##
## Set here rather than as an import option so the rule lives with the code that
## depends on it: a bed that does not loop plays for 45 seconds and then the game
## goes quiet, which is a bug nobody would look for in an `.import` file.
func _looping(stream: AudioStream) -> AudioStream:
	if stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = true
	elif stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = true
	elif stream is AudioStreamWAV:
		(stream as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD
	return stream


## The gain that brings `stream` to `BED_TARGET_DB`, or 0 dB for a stream this
## module has never measured.
func _normalised_gain(stream: AudioStream) -> float:
	if stream == null:
		return SILENT_DB
	var measured: Variant = BED_LEVELS.get(stream.resource_path, null)
	if measured == null:
		return 0.0
	return clampf(BED_TARGET_DB - float(measured), SILENT_DB, 24.0)


func _ensure_bus() -> void:
	if AudioServer.get_bus_index(BUS_NAME) >= 0:
		return
	AudioServer.add_bus()
	var index: int = AudioServer.bus_count - 1
	AudioServer.set_bus_name(index, BUS_NAME)
	AudioServer.set_bus_send(index, &"Master")
