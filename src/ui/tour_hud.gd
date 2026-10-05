extends CanvasLayer
class_name TourHUD
## The tour's face: a hint card that appears while standing in a stop, a
## progress badge in the corner, and the one-time start choice.
##
## Three rules from the design hold everything together:
##   * **Non-modal.** Nothing here pauses the world or captures the mouse —
##     the start choice answers to Enter (follow the tour) and Esc (dismiss it
##     and build), so a player whose mouse is captured by the camera is never
##     asked to go find a cursor.
##   * **Sandbox hides it all.** Choosing to build means choosing not to be
##     taught: the card, the badge and the choice box all go away.
##   * **Quiet.** The card carries one line and a requirement; a completed stop
##     says so and stops asking.

const PANEL_BG := Color(0.06, 0.07, 0.09, 0.86)
const PANEL_EDGE := Color(1.0, 1.0, 1.0, 0.14)
const TEXT_DIM := Color(0.78, 0.82, 0.88)

var _tour: DemoTour = null
var _card: PanelContainer
var _card_title: Label
var _card_hint: Label
var _card_req: Label
var _badge: PanelContainer
var _badge_label: Label
var _choice: PanelContainer
var _shown_stop: StringName = &""


func bind(tour: DemoTour) -> void:
	_tour = tour


func _ready() -> void:
	layer = UILayers.TOUR
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_choice()
	_build_badge()
	_build_card()
	set_process(true)


func _process(_delta: float) -> void:
	if _tour == null:
		return
	var unset: bool = _tour.mode == DemoTour.Mode.UNSET
	var sandbox: bool = _tour.mode == DemoTour.Mode.SANDBOX
	# The start card is the only surface while the choice is open — a hint card
	# under it would be teaching a tour the player has not agreed to yet.
	_choice.visible = unset and _tour.has_player()
	_badge.visible = not sandbox and not unset and _tour.stop_count() > 0
	if sandbox or unset:
		_card.visible = false
		return
	_refresh_card()


func _unhandled_input(event: InputEvent) -> void:
	if _tour == null or _tour.mode != DemoTour.Mode.UNSET or not _tour.has_player():
		return
	if event.is_action_pressed(&"ui_accept"):
		_tour.set_mode(DemoTour.Mode.TOUR)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"ui_cancel"):
		_tour.set_mode(DemoTour.Mode.SANDBOX)
		get_viewport().set_input_as_handled()


# --- construction ---------------------------------------------------------

func _build_choice() -> void:
	_choice = _make_panel()
	# Centre of the screen: anchors at the middle, and the container grows
	# outward from there so the box itself is centred whatever its size.
	_choice.set_anchors_preset(Control.PRESET_CENTER)
	_choice.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_choice.grow_vertical = Control.GROW_DIRECTION_BOTH
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	_choice.add_child(column)
	var title := _make_label("Propsmith 试玩草坪", 22)
	column.add_child(title)
	var body := _make_label(
		"这张图会带你过一遍已经做好的全部模块（约十分钟）。\n" +
		"熟悉沙盒的话可以直接开始建造，随时可在暂停菜单里重看导览。",
		15, TEXT_DIM
	)
	column.add_child(body)
	var keys := _make_label("Enter 跟随导览　·　Esc 直接开始建造", 15)
	column.add_child(keys)
	add_child(_choice)


func _build_badge() -> void:
	_badge = _make_panel()
	_badge.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_badge.grow_horizontal = Control.GROW_DIRECTION_END
	# Top-left: the minimap owns the top-right corner, and the badge must not
	# sit on top of it.
	_badge.position = Vector2(16, 16)
	_badge_label = _make_label("", 15)
	_badge.add_child(_badge_label)
	add_child(_badge)


func _build_card() -> void:
	_card = _make_panel()
	_card.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_card.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_card.position = Vector2(0, -24)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	_card.add_child(column)
	_card_title = _make_label("", 19)
	column.add_child(_card_title)
	_card_hint = _make_label("", 15, TEXT_DIM)
	column.add_child(_card_hint)
	_card_req = _make_label("", 14)
	column.add_child(_card_req)
	_card.visible = false
	add_child(_card)


func _make_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.border_color = PANEL_EDGE
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(14)
	panel.add_theme_stylebox_override("panel", style)
	return panel


func _make_label(text: String, size: int, color: Color = Color(0.95, 0.96, 1.0)) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return label


# --- live updates ---------------------------------------------------------

func _refresh_card() -> void:
	_badge_label.text = "演示 %d/%d" % [_tour.completed_count(), _tour.stop_count()]
	var stop: TourStop = _tour.active_stop()
	if stop == null:
		_card.visible = false
		_shown_stop = &""
		return
	if stop.stop_id != _shown_stop:
		_shown_stop = stop.stop_id
		_card_title.text = stop.display_name
		_card_hint.text = stop.hint
	var done: bool = _tour.is_completed(stop.stop_id)
	_card_req.text = "已完成 ✓" if done else "目标：%s" % stop.requirement
	_card_req.add_theme_color_override(
		"font_color", Color(0.55, 1.0, 0.6) if done else Color(1.0, 0.85, 0.5))
	_card.visible = true
