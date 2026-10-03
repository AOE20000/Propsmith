extends CanvasLayer
class_name CharacterPanel
## The in-game wardrobe: a paused, mouse-driven panel over the frozen world
## where every aspect of the player's look can be changed and seen immediately.
##
## Opened with the character-panel key (`V`). While open the tree is paused and
## the mouse is free — same contract as the build panel, but every click stays
## on the chrome, because editing a look needs no world raycasts. Each edit
## goes straight into the `CharacterAppearanceController`'s state, which
## re-applies it live, and the save system already owns that state, so a look
## survives save/load with no extra wiring here.

const LABEL_WIDTH: float = 90.0
const PANEL_WIDTH: float = 760.0

var _open: bool = false
var _swappers: Dictionary = {}
var _pickers: Dictionary = {}
var _sliders: Dictionary = {}
var _rows: VBoxContainer = null
var _blend_sliders: Dictionary = {}
var _blend_toggles: Dictionary = {}
var _blend_rows_built: bool = false


func _ready() -> void:
	layer = 45
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()


func _unhandled_input(event: InputEvent) -> void:
	if not _open:
		if event.is_action_pressed(&"character_panel") and GameState.mode == GameState.Mode.EXPLORING:
			_set_open(true)
			get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(&"character_panel") or event.is_action_pressed(&"pause"):
		_set_open(false)
		get_viewport().set_input_as_handled()


func _set_open(open: bool) -> void:
	_open = open
	visible = open
	get_tree().paused = open
	GameState.mode = GameState.Mode.CUSTOMIZING if open else GameState.Mode.EXPLORING
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if open else Input.MOUSE_MODE_CAPTURED
	if open:
		_ensure_blend_rows()
		_sync_controls()


## The controller rides on the player; group lookup keeps this panel decoupled
## from the boot order. A missing controller (model-less build) disables the
## panel rather than erroring.
func _controller() -> CharacterAppearanceController:
	var player: Node = get_tree().get_first_node_in_group(&"player")
	if player == null:
		return null
	return player.get_node_or_null("Appearance") as CharacterAppearanceController


func _build() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(root)

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.02, 0.03, 0.05, 0.55)
	root.add_child(dim)

	var chrome := PanelContainer.new()
	chrome.set_anchors_preset(Control.PRESET_CENTER)
	chrome.grow_horizontal = Control.GROW_DIRECTION_BOTH
	chrome.grow_vertical = Control.GROW_DIRECTION_BOTH
	chrome.custom_minimum_size = Vector2(PANEL_WIDTH, 0.0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.09, 0.11, 0.94)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(18)
	chrome.add_theme_stylebox_override("panel", style)
	root.add_child(chrome)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	chrome.add_child(column)

	var title := Label.new()
	title.text = "角色外观"
	title.add_theme_font_size_override("font_size", 22)
	column.add_child(title)

	var hint := Label.new()
	hint.text = "改动立即生效并随存档保存 · V 或 Esc 关闭"
	hint.modulate = Color(0.7, 0.78, 0.88)
	column.add_child(hint)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0.0, 430.0)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)

	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 6)
	scroll.add_child(rows)
	_rows = rows

	for id: StringName in CharacterAppearance.SWAP_GROUPS:
		rows.add_child(_build_swap_row(String(id), CharacterAppearance.SWAP_GROUPS[id]))
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0.0, 8.0)
	rows.add_child(spacer)
	for id: StringName in CharacterAppearance.COLOR_GROUPS:
		rows.add_child(_build_color_row(String(id), CharacterAppearance.COLOR_GROUPS[id]))
	var proportions_header := Label.new()
	proportions_header.text = "体形（滑杆实时生效）"
	proportions_header.modulate = Color(0.7, 0.78, 0.88)
	rows.add_child(proportions_header)
	for id: StringName in CharacterAppearance.DEFORM_GROUPS:
		rows.add_child(_build_deform_row(String(id), CharacterAppearance.DEFORM_GROUPS[id]))

	column.add_child(_build_footer())


func _build_swap_row(option_id: String, group: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.add_child(_row_label(group["label"]))

	var picker := OptionButton.new()
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var offset: int = 0 if group["required"] else 1
	if not group["required"]:
		picker.add_item("无")
	for variant: String in group["variants"]:
		picker.add_item(variant)
	picker.item_selected.connect(func(index: int) -> void:
		var controller := _controller()
		if controller != null:
			controller.set_option(option_id, index)
	)
	_swappers[option_id] = picker
	row.add_child(picker)
	return row


func _build_color_row(option_id: String, group: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.add_child(_row_label(group["label"]))

	var swatches := HBoxContainer.new()
	swatches.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	swatches.add_theme_constant_override("separation", 4)
	for color: Color in CharacterAppearance.palette(option_id):
		var button := Button.new()
		button.custom_minimum_size = Vector2(26.0, 26.0)
		button.focus_mode = Control.FOCUS_NONE
		var style := StyleBoxFlat.new()
		style.bg_color = color
		style.set_corner_radius_all(6)
		button.add_theme_stylebox_override("normal", style)
		button.add_theme_stylebox_override("hover", style)
		button.add_theme_stylebox_override("pressed", style)
		button.pressed.connect(func() -> void:
			_set_color(option_id, color)
		)
		swatches.add_child(button)
	row.add_child(swatches)

	var picker := ColorPickerButton.new()
	picker.custom_minimum_size = Vector2(52.0, 26.0)
	picker.color_changed.connect(func(color: Color) -> void:
		var controller := _controller()
		if controller != null:
			controller.set_option(option_id, color)
	)
	_pickers[option_id] = picker
	row.add_child(picker)
	return row


## A proportion slider: [-1, 1] drives bone-rest scaling live, so the body
## reshapes while the slider moves. The readout keeps the raw value visible —
## "taller" alone hides how much headroom is left before the clamp.
func _build_deform_row(option_id: String, group: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.add_child(_row_label(group["label"]))

	var slider := HSlider.new()
	slider.min_value = -1.0
	slider.max_value = 1.0
	slider.step = 0.02
	slider.custom_minimum_size = Vector2(0.0, 24.0)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(slider)

	var readout := Label.new()
	readout.custom_minimum_size = Vector2(46.0, 0.0)
	readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	readout.modulate = Color(0.7, 0.85, 0.95)
	row.add_child(readout)

	slider.value_changed.connect(func(value: float) -> void:
		readout.text = "%+.0f%%" % (value * 100.0)
		var controller := _controller()
		if controller != null:
			controller.set_option(option_id, value)
	)
	_sliders[option_id] = {"slider": slider, "readout": readout}
	return row


## Shape-key sliders are built lazily, on the first open, and only when the
## player's actual model resolves the curated shapes — the section must not
## exist for a Configura or capsule model, where every row would be dead. The
## component on the model is the single source of that answer.
func _ensure_blend_rows() -> void:
	if _blend_rows_built:
		return
	var controller := _controller()
	var model: Node3D = controller.model() if controller != null else null
	if model == null or ModelBlendShapes.find_on(model) == null:
		return
	_blend_rows_built = true
	var header := Label.new()
	header.text = "形体（形状键，实时生效）"
	header.modulate = Color(0.7, 0.78, 0.88)
	_rows.add_child(header)
	for group_id: StringName in ModelBlendShapes.SLIDER_GROUPS:
		var group: Dictionary = ModelBlendShapes.SLIDER_GROUPS[group_id]
		for slider: Dictionary in group["sliders"]:
			_rows.add_child(_build_blend_row(group, slider))
	for group_id: StringName in ModelBlendShapes.TOGGLE_GROUPS:
		var group: Dictionary = ModelBlendShapes.TOGGLE_GROUPS[group_id]
		for toggle: Dictionary in group["toggles"]:
			_rows.add_child(_build_blend_toggle_row(group, toggle))


## A shape-key slider: [0, 1] drives one morph on one mesh, live. Group labels
## are folded into the readout context (the group header above), so each row
## just names the dial.
func _build_blend_row(group: Dictionary, slider: Dictionary) -> HBoxContainer:
	var option_id := String(slider["id"])
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.add_child(_row_label("%s·%s" % [group["label"], slider["label"]]))

	var control := HSlider.new()
	control.min_value = 0.0
	control.max_value = 1.0
	control.step = 0.02
	control.custom_minimum_size = Vector2(0.0, 24.0)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(control)

	var readout := Label.new()
	readout.custom_minimum_size = Vector2(46.0, 0.0)
	readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	readout.modulate = Color(0.7, 0.85, 0.95)
	row.add_child(readout)

	control.value_changed.connect(func(value: float) -> void:
		readout.text = "%d%%" % roundi(value * 100.0)
		var controller := _controller()
		if controller != null:
			controller.set_option(option_id, value)
	)
	_blend_sliders[option_id] = {
		"slider": control, "readout": readout, "default": float(slider["default"]),
	}
	return row


## A garment toggle: plain visibility, on = worn. The authored look is fully
## dressed, so the checkbox starts checked and the readout is the piece name.
func _build_blend_toggle_row(group: Dictionary, toggle: Dictionary) -> HBoxContainer:
	var option_id := String(toggle["id"])
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.add_child(_row_label("%s·%s" % [group["label"], toggle["label"]]))

	var checkbox := CheckBox.new()
	checkbox.button_pressed = bool(toggle["default"])
	checkbox.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	row.add_child(checkbox)

	checkbox.toggled.connect(func(on: bool) -> void:
		var controller := _controller()
		if controller != null:
			controller.set_option(option_id, on)
	)
	_blend_toggles[option_id] = {"checkbox": checkbox, "default": bool(toggle["default"])}
	return row


func _build_footer() -> HBoxContainer:
	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 8)

	var random_button := Button.new()
	random_button.text = "随机"
	random_button.tooltip_text = "随机一套协调的穿搭（真实肤色与成套配色）与形体"
	random_button.pressed.connect(func() -> void:
		var controller := _controller()
		if controller != null:
			var state := CharacterAppearance.randomized_state()
			ModelBlendShapes.overlay_random(state)
			controller.replace_state(state)
		_sync_controls()
	)
	footer.add_child(random_button)

	var default_button := Button.new()
	default_button.text = "恢复默认"
	default_button.pressed.connect(func() -> void:
		var controller := _controller()
		if controller != null:
			controller.replace_state(CharacterAppearance.default_state())
		_sync_controls()
	)
	footer.add_child(default_button)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(spacer)

	var close_button := Button.new()
	close_button.text = "完成"
	close_button.pressed.connect(func() -> void: _set_open(false))
	footer.add_child(close_button)
	return footer


func _row_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(LABEL_WIDTH, 0.0)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return label


func _set_color(option_id: String, color: Color) -> void:
	var picker: ColorPickerButton = _pickers.get(option_id)
	if picker != null:
		picker.color = color
	var controller := _controller()
	if controller != null:
		controller.set_option(option_id, color)


## Push the controller's state back into every control — used on open and
## after randomize/reset, which replace the state wholesale.
func _sync_controls() -> void:
	var controller := _controller()
	if controller == null:
		return
	var state := controller.current_state()
	for option_id: String in _swappers:
		var picker: OptionButton = _swappers[option_id]
		var value: Variant = state.values.get(option_id, 0)
		picker.select(clampi(int(value), 0, picker.item_count - 1))
	for option_id: String in _pickers:
		var picker: ColorPickerButton = _pickers[option_id]
		var value: Variant = state.values.get(option_id, Color.WHITE)
		picker.color = value if value is Color else Color.WHITE
	for option_id: String in _sliders:
		var row: Dictionary = _sliders[option_id]
		var slider: HSlider = row["slider"]
		var readout: Label = row["readout"]
		var value := clampf(float(state.values.get(option_id, 0.0)), -1.0, 1.0)
		slider.set_value_no_signal(value)
		readout.text = "%+.0f%%" % (value * 100.0)
	for option_id: String in _blend_sliders:
		var row: Dictionary = _blend_sliders[option_id]
		var slider: HSlider = row["slider"]
		var readout: Label = row["readout"]
		var value := clampf(float(state.values.get(option_id, row["default"])), 0.0, 1.0)
		slider.set_value_no_signal(value)
		readout.text = "%d%%" % roundi(value * 100.0)
	for option_id: String in _blend_toggles:
		var row: Dictionary = _blend_toggles[option_id]
		var checkbox: CheckBox = row["checkbox"]
		checkbox.set_pressed_no_signal(bool(state.values.get(option_id, row["default"])))
