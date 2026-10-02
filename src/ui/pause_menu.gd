extends CanvasLayer
## Pause menu: resume, save/load, respawn, and a live list of loaded mods.
##
## Owns the pause state so gameplay nodes never have to agree on who paused the
## game: it flips `GameState.mode`, releases the mouse, and every other module
## reacts through that one value.

var _panel: PanelContainer = null
var _mod_list: VBoxContainer = null
var _status_label: Label = null


func _ready() -> void:
	layer = 20
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	Events.notification_posted.connect(_on_notification)


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(&"pause"):
		return
	# The build panel owns Esc while it is open — closing it must not also
	# toggle the pause menu underneath.
	if GameState.mode == GameState.Mode.BUILDING:
		return
	toggle()
	get_viewport().set_input_as_handled()


func toggle() -> void:
	set_paused(not visible)


func set_paused(paused: bool) -> void:
	visible = paused
	get_tree().paused = paused
	GameState.mode = GameState.Mode.PAUSED if paused else GameState.Mode.EXPLORING
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if paused else Input.MOUSE_MODE_CAPTURED
	if paused:
		_refresh_mod_list()
		_status_label.text = ""


func _on_notification(text: String, _level: int) -> void:
	if _status_label != null and visible:
		_status_label.text = text


func _build() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(root)

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.02, 0.03, 0.05, 0.62)
	root.add_child(dim)

	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_panel.custom_minimum_size = Vector2(420.0, 0.0)
	root.add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 22)
	margin.add_theme_constant_override("margin_right", 22)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_bottom", 18)
	_panel.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)

	var title := Label.new()
	title.text = "暂停"
	title.add_theme_font_size_override("font_size", 26)
	column.add_child(title)

	column.add_child(_make_button("继续游戏", func() -> void: set_paused(false)))
	column.add_child(_make_button("快速保存 (F5)", func() -> void: SaveSystem.save_game()))
	column.add_child(_make_button("读取存档 (F9)", func() -> void:
		if SaveSystem.load_game():
			set_paused(false)
	))
	column.add_child(_make_button("回到出生点", func() -> void:
		var player: Node = get_tree().get_first_node_in_group(&"player")
		if player != null and player.has_method("respawn"):
			player.call("respawn")
		set_paused(false)
	))
	column.add_child(_make_button("新世界（保留种子，重载工程）", func() -> void:
		SaveSystem.save_game("before_reset")
		GameState.reset_for_new_world()
		get_tree().paused = false
		get_tree().reload_current_scene()
	))

	_status_label = Label.new()
	_status_label.modulate = Color(0.7, 0.85, 0.95)
	column.add_child(_status_label)

	var mods_header := Label.new()
	mods_header.text = "已加载 Mod"
	mods_header.modulate = Color(0.7, 0.75, 0.8)
	column.add_child(mods_header)

	_mod_list = VBoxContainer.new()
	_mod_list.add_theme_constant_override("separation", 2)
	column.add_child(_mod_list)


func _make_button(text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0.0, 34.0)
	button.pressed.connect(action)
	return button


func _refresh_mod_list() -> void:
	if _mod_list == null:
		return
	for child: Node in _mod_list.get_children():
		child.queue_free()
	var lines: Array[String] = ModHost.describe()
	if lines.is_empty():
		var empty := Label.new()
		empty.text = "（无）把 mod 放进 res://mods/<名字>/ 即可加载"
		empty.modulate = Color(0.6, 0.63, 0.68)
		_mod_list.add_child(empty)
		return
	for line: String in lines:
		var label := Label.new()
		label.text = "· " + line
		_mod_list.add_child(label)
