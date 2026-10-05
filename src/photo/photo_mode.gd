extends Node
class_name PhotoMode
## A clean viewfinder: hides the interface, shoots the frame to disk, and lets the
## existing picture machinery be the filter.
##
## Registered as the `photo_mode` service.
##
## ## Filters are already built
##
## The roadmap asked for "hide the UI + filters". The filter list *is* the render
## style seam (`F2`) plus the look presets (`F4`) — which is a better answer than a
## bespoke list of photo filters, because it means every style a mod registers
## becomes a photo filter for free, and 3渲2 shot as a still is a real thing people
## do. So this module adds none.
##
## ## Why it is not a `GameState.Mode`
##
## It was tempting, and it would be wrong: `Freecam` leaves its own view whenever
## the mode changes away from `FREECAM`, so claiming a mode would make photo mode
## and the fly camera mutually exclusive. They should not be — flying around with
## the interface hidden is the obvious way to compose a shot. Instead this module
## *observes* modes and stands down when one takes over, which is what keeps `Esc`
## from opening an invisible menu.
##
## ## Capture is a two-frame operation
##
## Hiding the hint and shooting in the same frame photographs the frame that was
## already being drawn — the one with the hint in it. So the capture waits for the
## draw after the hint goes away, which is the whole reason `_capture` is a
## coroutine.

const OUTPUT_DIR: String = "user://photos"

## The modes that mean "something else is in charge now". Photo mode stands down for
## any of them rather than leaving an interface hidden behind a menu.
##
## A `var` rather than a `const`: these are enum members read through the `GameState`
## autoload, which is a lookup at instantiation rather than a constant expression.
var _yielding_modes: Array[int] = [
	GameState.Mode.PAUSED,
	GameState.Mode.MAP,
	GameState.Mode.DEAD,
	GameState.Mode.BUILDING,
	GameState.Mode.CUSTOMIZING,
]

var _active: bool = false
var _hint: CanvasLayer = null
## The layers this module hid, so they can be given back exactly.
var _hidden: Array[CanvasLayer] = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_hint()
	Events.game_mode_changed.connect(_on_game_mode_changed)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"toggle_photo_mode"):
		set_active(not _active)
		get_viewport().set_input_as_handled()
	elif _active and event.is_action_pressed(&"capture_photo"):
		var path: String = await capture()
		get_viewport().set_input_as_handled()
		if path.is_empty():
			# `capture()` has already said why; saying it twice only repeats it.
			return


func is_active() -> bool:
	return _active


func set_active(active: bool) -> void:
	if _active == active:
		return
	_active = active
	_set_ui_hidden(active)
	_hint.visible = active
	if active:
		Events.notify("拍照模式 — F10 拍摄 · F2 画风 · F4 时段 · P 退出", Events.NotifyLevel.INFO)


func describe() -> String:
	# Worth saying out loud: the same module on a headless run can hide the UI and
	# cannot take a picture, and a silent no-op there would look like a bug.
	var can_shoot: String = "可拍" if _can_capture() else "无渲染器（%s）" % DisplayServer.get_name()
	return "%s · %s · 输出 %s" % [
		"开启" if _active else "关闭", can_shoot, ProjectSettings.globalize_path(OUTPUT_DIR),
	]


## Save the current frame. Returns the path written, or empty when there is no
## renderer to read a frame from.
##
## `file_name` and `directory` exist so the probes can shoot into their own
## artefact directory through this same code path: `look_probe` shoots a dozen
## frames a run, and each one then exercises the real feature — the loop, the
## two-frame wait, the write — instead of a copy of it that would drift.
func capture(file_name: String = "", directory: String = OUTPUT_DIR) -> String:
	return await _capture(file_name, directory)


func _capture(file_name: String, directory: String) -> String:
	if not _can_capture():
		push_warning("[photo] no renderer to capture from (display server is '%s')" % DisplayServer.get_name())
		return ""
	var stamp: String = Time.get_datetime_string_from_system().replace(":", "-")
	var file: String = file_name if not file_name.is_empty() else "photo_%s.png" % stamp
	if not file.ends_with(".png"):
		file += ".png"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	var path: String = ProjectSettings.globalize_path(directory.path_join(file))

	# The hint goes away for the shot, and the shot happens on the *next* drawn
	# frame — see the note at the top of the file.
	var hint_was: bool = _hint.visible
	_hint.visible = false
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	if hint_was and _active:
		_hint.visible = true
	var error: Error = image.save_png(path)
	if error != OK:
		push_warning("[photo] could not write %s (error %d)" % [path, error])
		return ""
	print("[photo] saved %s" % path)
	Events.notify("已保存 %s" % file, Events.NotifyLevel.SUCCESS)
	Events.photo_saved.emit(path)
	return path


## Everything, not a curated list: a photo with a stray hint banner in it is a
## failed photo, and a list of layers to hide is a list that goes stale the first
## time a module adds one. This module's own hint is the single exception, and it
## is excluded by identity rather than by name.
func _set_ui_hidden(hidden: bool) -> void:
	if not hidden:
		for layer: CanvasLayer in _hidden:
			if is_instance_valid(layer):
				layer.visible = true
		_hidden.clear()
		return
	var stack: Array[Node] = [get_tree().root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child: Node in node.get_children():
			stack.append(child)
		if not (node is CanvasLayer) or node == _hint:
			continue
		var layer := node as CanvasLayer
		if layer.visible:
			_hidden.append(layer)
		layer.visible = false


func _on_game_mode_changed(_previous: int, current: int) -> void:
	if _active and _yielding_modes.has(current):
		set_active(false)


## Whether a frame can be read at all. The dummy renderer of a `--headless` run has
## no viewport texture to save, and asking for one is an engine error rather than a
## blank image — the same reasoning as `Ambience._can_play`.
static func _can_capture() -> bool:
	return DisplayServer.get_name() != "headless"


## A line of text low on the screen, and the only thing allowed to stay visible —
## and even it steps out of the way for the shot.
func _build_hint() -> void:
	_hint = CanvasLayer.new()
	_hint.name = "PhotoHint"
	_hint.layer = UILayers.PHOTO_HINT
	_hint.visible = false
	add_child(_hint)
	var label := Label.new()
	label.name = "Text"
	label.text = "拍照模式 · F10 拍摄 · F2 画风 · F4 时段 · P 退出"
	label.add_theme_font_size_override(&"font_size", 15)
	label.add_theme_color_override(&"font_color", Color(1.0, 1.0, 1.0, 0.85))
	label.add_theme_color_override(&"font_outline_color", Color(0.0, 0.0, 0.0, 0.7))
	label.add_theme_constant_override(&"outline_size", 4)
	label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	label.position = Vector2(24.0, -40.0)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint.add_child(label)
