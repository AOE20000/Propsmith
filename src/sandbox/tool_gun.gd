extends Node
class_name ToolGun
## The tool gun: the *held* input layer for sandbox tools. Registered as the
## `tool_gun` service because the build panel shares its tool state — both
## entries route clicks into the same `SandboxTool` instances, one while the
## world runs, one while it is paused for precise placement.
##
## The gun owns the tool roster (built-ins first, then mod tools through
## `ModContext.add_tool`), the wheel/menu cycling, and the aim raycast. Tools
## never see the player, the camera, or the input map — only hit dictionaries.

const AIM_RANGE: float = 25.0

## Every tool, in menu order. Rebuilt once per session after mods load.
var tools: Array[SandboxTool] = []
## Index into `tools`; -1 means "no tool selected" (clicks do nothing).
var current_index: int = -1

var _mod_count_at_build: int = -1


func _ready() -> void:
	_rebuild_tools()
	Events.mods_loaded.connect(func(_ids: PackedStringArray) -> void: _rebuild_tools())
	# The gun owns its picker (same pattern as the tour's HUD): hold Tab to
	# choose a tool from a radial menu. It reads this roster live, so mod tools
	# appear in it without either file knowing about the other.
	var wheel := ToolWheel.new()
	wheel.name = "ToolWheel"
	wheel.bind(self)
	add_child(wheel)


## The held tool, or null when nothing is selected.
func current_tool() -> SandboxTool:
	if current_index < 0 or current_index >= tools.size():
		return null
	return tools[current_index]


## Select by index (wheel/menu). Deselect notifications keep two-shot state honest.
func select_index(index: int) -> void:
	if index < -1 or index >= tools.size() or index == current_index:
		return
	var previous := current_tool()
	if previous != null:
		previous.deselected()
	current_index = index
	var tool := current_tool()
	if tool != null:
		tool.selected()
		Events.notify("工具：%s" % tool.display_name, Events.NotifyLevel.INFO)


## Select by id (the build panel and mod APIs use this).
func select_by_id(tool_id: StringName) -> void:
	for index: int in tools.size():
		if tools[index].tool_id == tool_id:
			select_index(index)
			return
	push_warning("ToolGun: unknown tool id '%s'" % tool_id)


## Rebuild the roster: built-in tools plus everything mods registered. The
## current selection is kept by id when it still exists.
func _rebuild_tools() -> void:
	var previous_id: StringName = current_tool().tool_id if current_tool() != null else &""
	tools.clear()
	tools.append(ConstraintTool.new(&"weld", "焊接", &"weld"))
	tools.append(ConstraintTool.new(&"rope", "绳索", &"rope"))
	tools.append(ConstraintTool.new(&"hinge", "铰链", &"hinge"))
	tools.append(PropTool.new(&"remover", "移除", &"remover"))
	tools.append(PropTool.new(&"painter", "上色", &"painter"))
	tools.append(PropTool.new(&"weight", "配重", &"weight"))
	tools.append(PropTool.new(&"duplicator", "复制器", &"duplicator"))
	for entry: Variant in ModHost.content_ordered(&"tool"):
		var tool: Variant = (entry as Dictionary).get("tool")
		if tool is SandboxTool:
			tools.append(tool)
	current_index = -1
	if not previous_id.is_empty():
		for index: int in tools.size():
			if tools[index].tool_id == previous_id:
				current_index = index
				break


func _unhandled_input(event: InputEvent) -> void:
	if GameState.mode != GameState.Mode.EXPLORING:
		return
	var belt: Variant = Services.get_service(&"tool_belt")
	if belt == null or (belt as ToolBelt).current != &"toolgun":
		return

	if event.is_action_pressed(&"attack"):
		_fire()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"wrench_freeze"):
		var tool := current_tool()
		var hit := _aim_hit()
		if tool != null and not hit.is_empty():
			tool.on_secondary(hit)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_WHEEL_UP:
			_cycle(-1)
			get_viewport().set_input_as_handled()
		elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_cycle(1)
			get_viewport().set_input_as_handled()


func _fire() -> void:
	var tool := current_tool()
	if tool == null:
		Events.notify("先用滚轮选择一个工具", Events.NotifyLevel.WARNING)
		return
	var hit := _aim_hit()
	if hit.is_empty():
		return
	tool.on_primary(hit)


## The aimed hit dictionary, or empty when nothing in range was hit. The ray
## starts at the crosshair while the mouse is captured and at the *pointer*
## when it is free — the building panel keeps the cursor visible, and a pick
## there has to follow where the player points.
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
	var query := PhysicsRayQueryParameters3D.create(from, from + direction * AIM_RANGE, 1)
	var hit: Dictionary = camera.get_world_3d().direct_space_state.intersect_ray(query)
	return hit


func _cycle(direction: int) -> void:
	if tools.is_empty():
		return
	var next: int = clampi(current_index + direction, -1, tools.size() - 1)
	if next == current_index:
		next = -1 if direction < 0 else 0
		if next == current_index:
			return
	select_index(next)
