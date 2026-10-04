extends CanvasLayer
## In-game heads-up display: interaction prompt, notifications, stamina, minimap
## and the debug overlay.
##
## Built entirely from code so the layout is reviewable as a diff instead of a
## hand-edited `.tscn` that drifts. Every element is driven by an `Events` signal,
## so the HUD holds no reference to the player, the world, or any gameplay module
## — it can be deleted and the game still runs.
##
## The minimap is not built here: it owns a 3D camera and a viewport, so it lives in
## `HudMinimap` and this class only tells it where the player is.

const NOTICE_LIFETIME: float = 3.6

var _prompt_label: Label = null
var _stamina_bar: ProgressBar = null
var _notice_box: VBoxContainer = null
var _debug_label: Label = null
var _discovery_label: Label = null
var _minimap: HudMinimap = null

var _debug_visible: bool = false
var _discovery_timer: float = 0.0
var _player: Node3D = null


func _ready() -> void:
	layer = UILayers.HUD
	_build()
	_connect_events()


func _connect_events() -> void:
	Events.interactable_focused.connect(_on_interactable_focused)
	Events.interactable_unfocused.connect(_on_interactable_unfocused)
	Events.notification_posted.connect(_on_notification)
	Events.player_stamina_changed.connect(_on_stamina_changed)
	Events.poi_discovered.connect(_on_poi_discovered)
	Events.player_spawned.connect(_on_player_spawned)


func _on_player_spawned(player: Node3D) -> void:
	_player = player


func _process(delta: float) -> void:
	if _discovery_timer > 0.0:
		_discovery_timer -= delta
		if _discovery_timer <= 0.0 and _discovery_label != null:
			_discovery_label.visible = false

	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group(&"player") as Node3D
	if _player != null and _minimap != null:
		_minimap.follow(_player.global_position)

	if _debug_visible:
		_refresh_debug()


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(&"ui_toggle_debug"):
		return
	_debug_visible = not _debug_visible
	if _debug_label != null:
		_debug_label.visible = _debug_visible
		if _debug_visible:
			_refresh_debug()
	get_viewport().set_input_as_handled()


func _on_interactable_focused(_interactable: Node, prompt: String) -> void:
	if _prompt_label != null:
		_prompt_label.text = "[E] %s" % prompt


func _on_interactable_unfocused(_interactable: Node) -> void:
	if _prompt_label != null:
		_prompt_label.text = ""


func _on_notification(text: String, level: int) -> void:
	if _notice_box == null:
		return
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	match level:
		Events.NotifyLevel.SUCCESS:
			label.modulate = Color(0.6, 0.95, 0.7)
		Events.NotifyLevel.WARNING:
			label.modulate = Color(1.0, 0.78, 0.5)
		_:
			label.modulate = Color(0.88, 0.92, 0.96)
	_notice_box.add_child(label)

	var timer: SceneTreeTimer = get_tree().create_timer(NOTICE_LIFETIME)
	timer.timeout.connect(func() -> void:
		if is_instance_valid(label):
			label.queue_free()
	)


func _on_stamina_changed(current: float, maximum: float) -> void:
	if _stamina_bar == null:
		return
	_stamina_bar.value = (current / maxf(maximum, 1.0)) * 100.0


func _on_poi_discovered(_poi_id: StringName, display_name: String, _position: Vector3) -> void:
	if _discovery_label == null:
		return
	_discovery_label.text = "◆ %s" % display_name
	_discovery_label.visible = true
	_discovery_timer = 4.2


## Debug overlay. Reports what the running build actually has, which is the point:
## services, mods, seed and streamed position, not a curated summary.
func _refresh_debug() -> void:
	if _debug_label == null:
		return
	var lines: PackedStringArray = PackedStringArray()
	var version: Variant = Engine.get_version_info().get("string", "?")
	lines.append("Godot %s | %d FPS" % [version, Engine.get_frames_per_second()])
	lines.append("模式 %d | 游玩 %s | 种子 %d" % [GameState.mode, GameState.format_play_time(), GameState.world_seed])

	if _player != null and is_instance_valid(_player):
		var position: Vector3 = _player.global_position
		lines.append("坐标 (%.1f, %.1f, %.1f)" % [position.x, position.y, position.z])
		var velocity: Variant = _player.get("velocity")
		if velocity is Vector3:
			lines.append("速度 %.2f m/s" % (velocity as Vector3).length())
		var stamina: Variant = _player.get("stamina")
		if stamina != null:
			lines.append("体力 %.0f" % float(stamina))

	lines.append("已发现地标 %d | 采集种类 %d" % [GameState.discovered_pois.size(), GameState.collected_items.size()])
	lines.append("服务：" + ", ".join(Services.names()))

	var mod_lines: Array[String] = ModHost.describe()
	if mod_lines.is_empty():
		lines.append("mod：无")
	else:
		for mod_line: String in mod_lines:
			lines.append("mod " + mod_line)

	var query: SurfaceQuery = Services.get_as(&"surface_query", &"SurfaceQuery") as SurfaceQuery
	if query != null and query.is_ready() and _player != null and is_instance_valid(_player):
		var position: Vector3 = _player.global_position
		lines.append("脚下地表 %.1f m（%s）" % [
			query.height_at(position.x, position.z), query.surface_kind(position.x, position.z),
		])

	_debug_label.text = "\n".join(lines)


func _build() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	var crosshair := Label.new()
	crosshair.text = "·"
	crosshair.set_anchors_preset(Control.PRESET_CENTER)
	crosshair.grow_horizontal = Control.GROW_DIRECTION_BOTH
	crosshair.grow_vertical = Control.GROW_DIRECTION_BOTH
	crosshair.modulate = Color(1.0, 1.0, 1.0, 0.45)
	crosshair.add_theme_font_size_override("font_size", 26)
	root.add_child(crosshair)

	_prompt_label = Label.new()
	_prompt_label.set_anchors_preset(Control.PRESET_CENTER)
	_prompt_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_prompt_label.grow_vertical = Control.GROW_DIRECTION_BOTH
	_prompt_label.offset_top = 46.0
	_prompt_label.offset_bottom = 76.0
	_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt_label.add_theme_font_size_override("font_size", 18)
	root.add_child(_prompt_label)

	_discovery_label = Label.new()
	_discovery_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_discovery_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_discovery_label.offset_top = 110.0
	_discovery_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_discovery_label.add_theme_font_size_override("font_size", 24)
	_discovery_label.modulate = Color(1.0, 0.92, 0.6)
	_discovery_label.visible = false
	root.add_child(_discovery_label)

	_notice_box = VBoxContainer.new()
	_notice_box.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_notice_box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_notice_box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_notice_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_notice_box.offset_top = -190.0
	_notice_box.offset_bottom = -130.0
	_notice_box.add_theme_constant_override("separation", 4)
	root.add_child(_notice_box)

	var bottom_left := VBoxContainer.new()
	bottom_left.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	bottom_left.offset_left = 24.0
	bottom_left.offset_top = -84.0
	bottom_left.offset_bottom = -24.0
	bottom_left.add_theme_constant_override("separation", 6)
	root.add_child(bottom_left)

	_stamina_bar = ProgressBar.new()
	_stamina_bar.min_value = 0.0
	_stamina_bar.max_value = 100.0
	_stamina_bar.value = 100.0
	_stamina_bar.show_percentage = false
	_stamina_bar.custom_minimum_size = Vector2(190.0, 10.0)
	bottom_left.add_child(_stamina_bar)

	var stamina_caption := Label.new()
	stamina_caption.text = "体力（Shift 冲刺）"
	stamina_caption.modulate = Color(0.75, 0.82, 0.9)
	bottom_left.add_child(stamina_caption)

	# A widget rather than inline construction: it brings its own 3D camera and
	# viewport, which is a different kind of thing from the 2D elements above.
	_minimap = HudMinimap.new()
	root.add_child(_minimap)

	_debug_label = Label.new()
	_debug_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_debug_label.offset_left = 20.0
	_debug_label.offset_top = 20.0
	_debug_label.add_theme_font_size_override("font_size", 13)
	_debug_label.modulate = Color(0.85, 0.95, 1.0, 0.9)
	_debug_label.visible = false
	root.add_child(_debug_label)
