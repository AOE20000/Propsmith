extends CanvasLayer
## Boot progress. Subscribes to the world-generation events so it needs no direct
## reference to the builder — the loading screen is a pure observer.

var _title: Label = null
var _step_label: Label = null
var _bar: ProgressBar = null
var _hint: Label = null


func _ready() -> void:
	layer = UILayers.LOADING_SCREEN
	_build()
	Events.world_generation_progress.connect(_on_progress)


func _on_progress(step: String, ratio: float) -> void:
	if _step_label != null:
		_step_label.text = step
	if _bar != null:
		_bar.value = clampf(ratio, 0.0, 1.0) * 100.0


func _build() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	var background := ColorRect.new()
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	background.color = Color(0.05, 0.06, 0.08, 1.0)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(background)

	var centre := VBoxContainer.new()
	centre.set_anchors_preset(Control.PRESET_CENTER)
	centre.grow_horizontal = Control.GROW_DIRECTION_BOTH
	centre.grow_vertical = Control.GROW_DIRECTION_BOTH
	centre.custom_minimum_size = Vector2(460.0, 0.0)
	centre.add_theme_constant_override("separation", 14)
	root.add_child(centre)

	_title = Label.new()
	_title.text = "Propsmith"
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", 34)
	centre.add_child(_title)

	var subtitle := Label.new()
	subtitle.text = "沙盒游乐场 · 原创原型"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.modulate = Color(0.72, 0.78, 0.85)
	centre.add_child(subtitle)

	_bar = ProgressBar.new()
	_bar.min_value = 0.0
	_bar.max_value = 100.0
	_bar.value = 0.0
	_bar.show_percentage = false
	_bar.custom_minimum_size = Vector2(460.0, 12.0)
	centre.add_child(_bar)

	_step_label = Label.new()
	_step_label.text = "准备中…"
	_step_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_step_label.modulate = Color(0.8, 0.85, 0.9)
	centre.add_child(_step_label)

	_hint = Label.new()
	_hint.text = "WASD 移动 · Shift 冲刺 · Space 跳跃 · E 交互 · 左键 攻击 · Esc 菜单"
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.modulate = Color(0.55, 0.6, 0.66)
	centre.add_child(_hint)
