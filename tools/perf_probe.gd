extends Node
## Dev-only frame-cost probe.
##
## "Is the crowd cheap?" is not a question a headless test can answer: the dummy
## renderer does no work, so every number it could produce is a lie about the one
## that matters. This boots the real game in a window, with vsync off and low
## processor mode disabled — otherwise the measurement is either the monitor's
## refresh rate or the OS throttling a background window — lets the scene settle,
## then samples a window of frames.
##
## Structural counts and timings are reported separately, on purpose. The counts
## (draw calls, objects in frame, node count) are exact and repeatable, and they
## are the evidence that a change did something. The timings are indicative: this
## machine runs an editor, and the same build has been seen to sample ±20 % run to
## run. Compare *minima* against builds measured on this machine in the same
## session, and never against a number from somewhere else.
##
## Run:  godot --path . res://tools/perf_probe.tscn
## Env:  DSH_MAP_SOURCE (which map), DSH_PERF_SETTLE, DSH_PERF_FRAMES

const DEFAULT_SETTLE: int = 90
const DEFAULT_SAMPLES: int = 300

## 0 waiting for the world, 1 settling, 2 sampling.
var _stage: int = 0
var _frames: int = 0
var _settle: int = DEFAULT_SETTLE
var _wanted: int = DEFAULT_SAMPLES
var _frame_ms: PackedFloat32Array = PackedFloat32Array()


func _ready() -> void:
	_settle = _env_int("DSH_PERF_SETTLE", DEFAULT_SETTLE)
	_wanted = _env_int("DSH_PERF_FRAMES", DEFAULT_SAMPLES)
	var packed: PackedScene = load("res://src/boot/startup.tscn")
	add_child(packed.instantiate())
	Events.world_ready.connect(_on_world_ready)


func _on_world_ready(_world: Node3D) -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	# A probe driven from a terminal has an unfocused window, which is exactly when
	# Godot throttles — and a throttled frame time is not a frame time.
	OS.low_processor_usage_mode = false
	_stage = 1
	_frames = 0


func _process(_delta: float) -> void:
	if _stage == 0:
		return
	_frames += 1
	if _stage == 1:
		if _frames >= _settle:
			_stage = 2
			_frames = 0
		return
	_frame_ms.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	if _frame_ms.size() >= _wanted:
		_report()
		get_tree().quit(0)


func _report() -> void:
	var sorted_ms: PackedFloat32Array = _frame_ms.duplicate()
	sorted_ms.sort()
	var count: int = sorted_ms.size()
	var total: float = 0.0
	for value: float in sorted_ms:
		total += value
	var best: float = sorted_ms[0]
	var median: float = sorted_ms[count / 2]
	var p95: float = sorted_ms[mini(int(float(count) * 0.95), count - 1)]
	var worst: float = sorted_ms[count - 1]

	print("[perf] frames %d · best %.2f ms (%.0f fps) · median %.2f ms (%.0f fps) · mean %.2f ms · p95 %.2f ms · worst %.2f ms" % [
		count, best, 1000.0 / maxf(best, 0.001), median, 1000.0 / maxf(median, 0.001),
		total / float(count), p95, worst,
	])
	print("[perf] draw calls %d · objects in frame %d · nodes %d · physics 3D active %d" % [
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)),
	])
	print("[perf] video mem %.0f MB · static mem %.0f MB · orphan nodes %d" % [
		Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
	])
	print("[perf] citizen figures %s" % NpcFigure.cost_report())


func _env_int(name: String, fallback: int) -> int:
	var raw: String = OS.get_environment(name).strip_edges()
	return int(raw) if raw.is_valid_int() else fallback
