extends CanvasLayer
class_name ToolWheel
## Hold Tab for a radial picker of the tool gun's tools.
##
## A hold, not a toggle: releasing is the commit, so there is no mode to escape
## from and no confirmation step. The gesture matches the sandbox convention,
## and the wheel reads the roster straight off the tool gun — built-ins first,
## mod tools after — so a registered tool appears without this file changing.
##
## The cursor is released while the wheel is up (the game otherwise keeps it
## captured). Pointing with a visible cursor is unambiguous, needs no virtual
## pointer, and the camera rig already ignores mouse motion while the cursor is
## free, so the view holds still while choosing. Releasing over the centre
## dead zone — or pressing Esc — commits nothing and leaves the tool alone.

## Radius of the whole disc, in pixels.
const RADIUS: float = 200.0
## Where a tool's label sits.
const LABEL_RADIUS: float = 138.0
## Inside this radius nothing is picked.
const DEAD_ZONE: float = 44.0

var _gun: ToolGun = null
var _open: bool = false
var _hover: int = -1
var _disc: Disc = null
var _labels: Array[Label] = []


func bind(gun: ToolGun) -> void:
	_gun = gun


func _ready() -> void:
	layer = UILayers.TOOL_WHEEL
	process_mode = Node.PROCESS_MODE_ALWAYS
	_disc = Disc.new()
	_disc.wheel = self
	_disc.set_anchors_preset(Control.PRESET_FULL_RECT)
	_disc.visible = false
	add_child(_disc)
	set_process(true)


func _process(_delta: float) -> void:
	if not _open:
		return
	_hover = index_at(get_viewport().get_mouse_position())
	_disc.queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"tool_wheel"):
		if _can_open():
			_open_wheel()
			get_viewport().set_input_as_handled()
		return
	if event.is_action_released(&"tool_wheel"):
		if _open:
			_close_wheel(true)
			get_viewport().set_input_as_handled()
		return
	if _open and event.is_action_pressed(&"ui_cancel"):
		_close_wheel(false)
		get_viewport().set_input_as_handled()


## The wheel belongs to the tool gun, so it only comes up while that gun is
## actually held and the world is running.
func _can_open() -> bool:
	if _gun == null or _gun.tools.is_empty():
		return false
	if GameState.mode != GameState.Mode.EXPLORING:
		return false
	var belt: Variant = Services.get_service(&"tool_belt")
	return belt != null and (belt as ToolBelt).current == &"toolgun"


func _open_wheel() -> void:
	_open = true
	_hover = _gun.current_index
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_build_labels()
	_disc.visible = true


## `commit` distinguishes "released over a sector" from "cancelled": a cancel
## leaves the tool as it was.
func _close_wheel(commit: bool) -> void:
	_open = false
	_disc.visible = false
	for label: Label in _labels:
		label.queue_free()
	_labels.clear()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if commit and _hover >= 0:
		_gun.select_index(_hover)


func _build_labels() -> void:
	for label: Label in _labels:
		label.queue_free()
	_labels.clear()
	if _gun == null:
		return
	var centre := viewport_centre()
	var count: int = _gun.tools.size()
	for i: int in count:
		var label := Label.new()
		label.text = _gun.tools[i].display_name
		label.add_theme_font_size_override("font_size", 17)
		label.add_theme_color_override("font_color", Color(0.95, 0.96, 1.0))
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.position = centre + direction_of(i, count) * LABEL_RADIUS \
			- Vector2(60.0, 10.0)
		label.size = Vector2(120.0, 22.0)
		_disc.add_child(label)
		_labels.append(label)


## Screen position of a sector's label — also what the tests exercise through
## `index_for_offset`.
func direction_of(index: int, count: int) -> Vector2:
	var step: float = TAU / float(maxi(count, 1))
	var angle: float = -PI * 0.5 + step * float(index)
	return Vector2(cos(angle), sin(angle))


func viewport_centre() -> Vector2:
	return get_viewport().get_visible_rect().size * 0.5


## The sector under a screen position, or -1 for the dead zone.
func index_at(screen_pos: Vector2) -> int:
	var count: int = 0 if _gun == null else _gun.tools.size()
	return index_for_offset(screen_pos - viewport_centre(), count)


## Sector from an offset relative to the centre: sector 0 sits at the top and
## the rest run clockwise; the centre is a dead zone. Static so it can be
## tested without a window.
static func index_for_offset(offset: Vector2, count: int) -> int:
	if count <= 0 or offset.length() < DEAD_ZONE:
		return -1
	var step: float = TAU / float(count)
	# Sector 0 starts at the top (-90°) and grows clockwise, matching
	# `direction_of`.
	var angle: float = wrapf(atan2(offset.y, offset.x) + PI * 0.5, 0.0, TAU)
	return int(floor(angle / step)) % count


## The disc itself, drawn rather than assembled from nodes: sectors plus the
## highlight are a few arcs, while making them Controls would be a pile of
## polygons that all need re-laying out on every resize.
class Disc extends Control:
	var wheel: ToolWheel = null

	func _draw() -> void:
		if wheel == null or wheel._gun == null:
			return
		var centre: Vector2 = wheel.viewport_centre()
		var count: int = wheel._gun.tools.size()
		if count == 0:
			return
		var step: float = TAU / float(count)
		for i: int in count:
			var start: float = -PI * 0.5 + step * float(i)
			var points := PackedVector2Array()
			var arc_steps: int = 20
			for s: int in arc_steps + 1:
				var a: float = start + step * float(s) / float(arc_steps)
				points.append(centre + Vector2(cos(a), sin(a)) * ToolWheel.RADIUS)
			points.append(centre)
			var hovered: bool = i == wheel._hover
			var fill := Color(0.10, 0.12, 0.16, 0.72)
			if hovered:
				fill = Color(0.28, 0.42, 0.62, 0.86)
			elif i == wheel._gun.current_index:
				fill = Color(0.16, 0.20, 0.26, 0.80)
			draw_colored_polygon(points, fill)
			draw_polyline(points, Color(1.0, 1.0, 1.0, 0.16), 1.5)
		draw_circle(centre, ToolWheel.DEAD_ZONE, Color(0.06, 0.07, 0.09, 0.9))
		draw_arc(centre, ToolWheel.RADIUS, 0.0, TAU, 64,
			Color(1.0, 1.0, 1.0, 0.22), 2.0)
		var held: String = wheel._gun.current_tool().display_name \
			if wheel._gun.current_tool() != null else "未选择工具"
		var font := ThemeDB.fallback_font
		draw_string(font, centre + Vector2(-70.0, 6.0), held,
			HORIZONTAL_ALIGNMENT_CENTER, 140.0, 15,
			Color(0.92, 0.94, 1.0))
