extends CanvasLayer
class_name BuildingPanel
## The paused build mode: a full-screen translucent panel over the frozen world
## where tools are picked, parameters live, and clicks route to the held tool —
## everything precise that realtime play is bad at.
##
## Opened with the build-panel key (`~`). While open: the tree is paused, the
## mouse is free, and clicks on the world (the panel chrome ignores the mouse,
## the click falls through) raycast into the frozen scene and feed the *same*
## `SandboxTool` instances the held tool gun uses. Close it and physics resumes
## with every constraint and prop exactly where the player left them.
##
## PROCESS_MODE_ALWAYS is what lets this node listen while paused; everything it
## calls must tolerate a paused tree (raycasts do; spawning does — the new prop
## simply waits for the unpause to fall).

const TOOL_LIST_WIDTH: float = 250.0

var _tool_gun: ToolGun = null
var _spawner: PropSpawner = null
var _open: bool = false
var _overlay: ColorRect = null
var _tool_list: VBoxContainer = null
var _status: Label = null


func _ready() -> void:
	layer = UILayers.BUILDING_PANEL
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()


func _unhandled_input(event: InputEvent) -> void:
	if not _open:
		if event.is_action_pressed(&"building_panel") and GameState.mode == GameState.Mode.EXPLORING:
			_set_open(true)
			get_viewport().set_input_as_handled()
		return

	# While open, the panel owns everything: Esc/~ close it, clicks on the world
	# feed the held tool, clicks on chrome land on the chrome.
	if event.is_action_pressed(&"building_panel") or event.is_action_pressed(&"pause"):
		_set_open(false)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(&"attack"):
		var tool := _tool_gun.current_tool() if _tool_gun != null else null
		var hit := _aim_hit()
		if tool != null and not hit.is_empty():
			tool.on_primary(hit)
			_refresh_status(tool)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(&"wrench_freeze"):
		var tool := _tool_gun.current_tool() if _tool_gun != null else null
		var hit := _aim_hit()
		if tool != null and not hit.is_empty():
			tool.on_secondary(hit)
		get_viewport().set_input_as_handled()
		return


func _set_open(open: bool) -> void:
	_open = open
	visible = open
	get_tree().paused = open
	GameState.mode = GameState.Mode.BUILDING if open else GameState.Mode.EXPLORING
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if open else Input.MOUSE_MODE_CAPTURED
	if _tool_gun == null:
		_tool_gun = Services.get_as(&"tool_gun", &"ToolGun") as ToolGun
	if open:
		_rebuild_tools()


## The aimed hit. The source of the ray follows the mouse mode: captured means
## the crosshair (the camera's forward), free means the *pointer* — the panel
## runs with a visible cursor, and picking by crosshair there was a trap: the
## cursor moved but the ray did not, so every click landed on whatever the
## camera happened to centre on and a two-shot tool could never choose its
## second anchor. The reported workaround — close the panel, walk and turn,
## reopen — is exactly what that forced.
func _aim_hit() -> Dictionary:
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null:
		return {}
	var from: Vector3
	var direction: Vector3
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		from = camera.global_position
		direction = -camera.global_transform.basis.z
	else:
		var screen: Vector2 = get_viewport().get_mouse_position()
		from = camera.project_ray_origin(screen)
		direction = camera.project_ray_normal(screen)
	var query := PhysicsRayQueryParameters3D.create(from, from + direction * 60.0, 1)
	return camera.get_world_3d().direct_space_state.intersect_ray(query)


func _refresh_status(tool: SandboxTool) -> void:
	if _status != null:
		_status.text = "%s — 左键应用 · 右键取消选择 · ~ 恢复游戏" % tool.display_name


func _build() -> void:
	_overlay = ColorRect.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.color = Color(0.04, 0.06, 0.09, 0.45)
	# Clicks pass through the tint to the viewport raycast; only the chrome
	# below stops the mouse.
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_overlay)

	var chrome := PanelContainer.new()
	chrome.name = "Chrome"
	chrome.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	chrome.grow_vertical = Control.GROW_DIRECTION_BOTH
	chrome.custom_minimum_size = Vector2(TOOL_LIST_WIDTH, 0.0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.09, 0.11, 0.9)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(12)
	chrome.add_theme_stylebox_override("panel", style)
	# The chrome is the only thing that stops clicks — the rest of the screen
	# is the workspace.
	chrome.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(chrome)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	chrome.add_child(column)

	var title := Label.new()
	title.text = "建造面板（世界已暂停）"
	title.add_theme_font_size_override("font_size", 16)
	column.add_child(title)

	var tools_header := Label.new()
	tools_header.text = "工具"
	tools_header.modulate = Color(0.7, 0.78, 0.88)
	column.add_child(tools_header)

	_tool_list = VBoxContainer.new()
	_tool_list.add_theme_constant_override("separation", 2)
	column.add_child(_tool_list)

	var props_header := Label.new()
	props_header.text = "快速生成"
	props_header.modulate = Color(0.7, 0.78, 0.88)
	column.add_child(props_header)

	var prop_row := HBoxContainer.new()
	prop_row.add_theme_constant_override("separation", 4)
	column.add_child(prop_row)
	for entry: Dictionary in PropCatalog.entries():
		var prop_id: StringName = StringName(entry.get("id", &""))
		var button := Button.new()
		button.text = String(entry.get("display_name", ""))
		button.tooltip_text = "在准星处生成（暂停中生成，恢复后落下）"
		button.pressed.connect(func() -> void:
			if _spawner == null:
				_spawner = Services.get_as(&"prop_spawner", &"PropSpawner") as PropSpawner
			if _spawner != null:
				_spawner.spawn(prop_id, _aim_point_ahead())
		)
		prop_row.add_child(button)

	_status = Label.new()
	_status.text = "选一个工具，然后在画面上点击"
	_status.modulate = Color(0.7, 0.85, 0.95)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(TOOL_LIST_WIDTH - 24.0, 0.0)
	column.add_child(_status)


## Spawn ahead of the camera — while paused the props wait in place, which is
## exactly the "place it precisely, then unpause" flow this panel exists for.
func _aim_point_ahead() -> Vector3:
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null:
		return Vector3.ZERO
	return camera.global_position - camera.global_transform.basis.z * 4.0


func _rebuild_tools() -> void:
	if _tool_gun == null:
		_tool_gun = Services.get_as(&"tool_gun", &"ToolGun") as ToolGun
	if _tool_gun == null or _tool_list == null:
		return
	for child: Node in _tool_list.get_children():
		child.queue_free()
	var index: int = 0
	for tool: SandboxTool in _tool_gun.tools:
		var tool_id: StringName = tool.tool_id
		var button := Button.new()
		button.text = tool.display_name
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.pressed.connect(func() -> void:
			_tool_gun.select_by_id(tool_id)
			_status.text = "%s — 左键应用 · 右键取消 · ~ 恢复" % tool.display_name
		)
		_tool_list.add_child(button)
		index += 1
