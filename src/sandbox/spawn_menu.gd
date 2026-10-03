extends CanvasLayer
class_name SpawnMenu
## The spawn menu: hold-free toggle on the spawn-menu key, one list of every
## prop the catalogue offers (built-ins and mods, already merged), a clear-all,
## and spawning at the crosshair rather than at the player's feet.
##
## Deliberately plain for P0 — a scrolling button list. The mod-facing contract
## is what matters: anything registered through `ModContext.add_prop_factory`
## appears here with zero menu-side changes, which is the same promise the
## vehicle system makes.

var _spawner: PropSpawner = null
var _panel: PanelContainer = null
var _list: VBoxContainer = null
var _open: bool = false


func _ready() -> void:
	layer = 40
	_build_panel()
	visible = false


func _unhandled_input(event: InputEvent) -> void:
	if GameState.mode != GameState.Mode.EXPLORING:
		return
	if event.is_action_pressed(&"spawn_menu"):
		_set_open(not _open)
		get_viewport().set_input_as_handled()
	elif _open and event.is_action_pressed(&"pause"):
		# Esc with the menu open closes the menu instead of pausing.
		_set_open(false)
		get_viewport().set_input_as_handled()


func _set_open(open: bool) -> void:
	_open = open
	visible = open
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if open else Input.MOUSE_MODE_CAPTURED
	if open:
		_rebuild_list()


## Spawn at the crosshair: the point the camera is looking at, offset along the
## surface normal when there is one (so props sit on surfaces, not in them).
func _spawn_at_crosshair(prop_id: StringName) -> void:
	if _spawner == null:
		_spawner = Services.get_as(&"prop_spawner", &"PropSpawner") as PropSpawner
	if _spawner == null:
		return
	var camera: Camera3D = get_viewport().get_camera_3d()
	var target := Vector3.ZERO
	if camera != null:
		var query := PhysicsRayQueryParameters3D.create(
			camera.global_position,
			camera.global_position - camera.global_transform.basis.z * 60.0,
			1,
		)
		var hit: Dictionary = camera.get_world_3d().direct_space_state.intersect_ray(query)
		if not hit.is_empty():
			var normal: Vector3 = hit.get("normal", Vector3.UP)
			var extents: Vector3 = _prop_half_extents(prop_id)
			target = (hit["position"] as Vector3) + normal * maxf(extents.y, 0.4) + Vector3.UP * 0.1
		else:
			target = camera.global_position - camera.global_transform.basis.z * 3.0
	var spawned: RigidBody3D = _spawner.spawn(prop_id, target)
	if spawned != null:
		Events.notify("已生成 %s" % PropCatalog.find(prop_id).get("display_name", ""), Events.NotifyLevel.INFO)


## Rough vertical half-extent from the catalog factory, so the spawn offset
## clears the ground without physics popping. Cheap AABB probe on a throwaway.
func _prop_half_extents(prop_id: StringName) -> Vector3:
	var definition: Dictionary = PropCatalog.find(prop_id)
	var factory: Callable = definition.get("factory", Callable())
	if not factory.is_valid():
		return Vector3.ONE * 0.4
	var probe: Variant = factory.call()
	if probe is RigidBody3D:
		var body := probe as RigidBody3D
		var visual := body.get_node_or_null("Visual") as MeshInstance3D
		var extents := Vector3.ONE * 0.4
		if visual != null and visual.mesh != null:
			extents = visual.mesh.get_aabb().size * 0.5
		body.free()
		return extents
	return Vector3.ONE * 0.4


func _rebuild_list() -> void:
	for child: Node in _list.get_children():
		(child as Node).queue_free()

	var category_order: PackedStringArray = PackedStringArray()
	var by_category: Dictionary = {}
	for entry: Dictionary in PropCatalog.entries():
		var category: String = String(entry.get("category", "misc"))
		if not by_category.has(category):
			category_order.append(category)
			by_category[category] = []
		(by_category[category] as Array).append(entry)

	for category: String in category_order:
		var heading := Label.new()
		heading.text = category
		heading.add_theme_font_size_override("font_size", 14)
		heading.modulate = Color(1.0, 1.0, 1.0, 0.6)
		_list.add_child(heading)
		for entry: Dictionary in by_category[category]:
			var prop_id: StringName = StringName(entry.get("id", &""))
			_list.add_child(_spawn_button(String(entry.get("display_name", "")), prop_id))

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0.0, 8.0)
	_list.add_child(spacer)

	# NPCs: the built-in citizen plus every mod kind. Spawning uses the same
	# crosshair placement as props.
	var npc_spawner := func(npc_id: StringName) -> void:
		if _spawner == null:
			_spawner = Services.get_as(&"prop_spawner", &"PropSpawner") as PropSpawner
		if _spawner == null:
			return
		var camera: Camera3D = get_viewport().get_camera_3d()
		var target: Vector3 = Vector3.ZERO
		if camera != null:
			var probe := PhysicsRayQueryParameters3D.create(
				camera.global_position,
				camera.global_position - camera.global_transform.basis.z * 60.0,
				1,
			)
			var hit: Dictionary = camera.get_world_3d().direct_space_state.intersect_ray(probe)
			target = (hit["position"] as Vector3) + Vector3.UP if not hit.is_empty() else camera.global_position - camera.global_transform.basis.z * 3.0
		_spawner.spawn_npc(npc_id, target, randi())

	var npcs_header := Label.new()
	npcs_header.text = "npc"
	npcs_header.add_theme_font_size_override("font_size", 14)
	npcs_header.modulate = Color(1.0, 1.0, 1.0, 0.6)
	_list.add_child(npcs_header)
	for entry: Dictionary in _spawner_npc_entries():
		var npc_id: StringName = StringName(entry.get("id", &""))
		_list.add_child(_action_button(String(entry.get("display_name", "")), func() -> void:
			npc_spawner.call(npc_id)
		))
	# The VRM appearance is a per-citizen choice: same schedule logic, humanoid
	# skin when the sample model has been imported.
	_list.add_child(_action_button("市民（VRM 外观）", func() -> void:
		if _spawner == null:
			_spawner = Services.get_as(&"prop_spawner", &"PropSpawner") as PropSpawner
		if _spawner == null:
			return
		var camera: Camera3D = get_viewport().get_camera_3d()
		var target: Vector3 = Vector3.ZERO
		if camera != null:
			var probe := PhysicsRayQueryParameters3D.create(
				camera.global_position,
				camera.global_position - camera.global_transform.basis.z * 60.0,
				1,
			)
			var hit: Dictionary = camera.get_world_3d().direct_space_state.intersect_ray(probe)
			target = (hit["position"] as Vector3) + Vector3.UP if not hit.is_empty() else camera.global_position - camera.global_transform.basis.z * 3.0
		_spawner.spawn_citizen(target, randi(), &"vrm")
	))

	var spacer2 := Control.new()
	spacer2.custom_minimum_size = Vector2(0.0, 8.0)
	_list.add_child(spacer2)
	_list.add_child(_action_button("清空全部道具", func() -> void:
		if _spawner != null:
			_spawner.clear_all_recorded()
	))


## The spawner is resolved lazily here; its npc catalogue covers the built-in
## citizen and mod registrations.
func _spawner_npc_entries() -> Array[Dictionary]:
	if _spawner == null:
		_spawner = Services.get_as(&"prop_spawner", &"PropSpawner") as PropSpawner
	if _spawner != null:
		return _spawner.npc_entries()
	return []


func _spawn_button(label: String, prop_id: StringName) -> Button:
	var button := Button.new()
	button.text = label
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.pressed.connect(func() -> void:
		_spawn_at_crosshair(prop_id)
		# Staying open keeps the menu the fast path for repeated spawning; the
		# mouse stays visible and the player closes with the menu key.
	)
	return button


func _action_button(label: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = label
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.pressed.connect(action)
	return button


func _build_panel() -> void:
	_panel = PanelContainer.new()
	_panel.name = "SpawnPanel"
	_panel.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.09, 0.11, 0.88)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(12)
	_panel.add_theme_stylebox_override("panel", style)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(240.0, 420.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_panel.add_child(scroll)

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 4)
	scroll.add_child(_list)

	add_child(_panel)

	var hint := Label.new()
	hint.text = "点击生成到准星 · 再按 Q 关闭"
	hint.add_theme_font_size_override("font_size", 12)
	hint.modulate = Color(1.0, 1.0, 1.0, 0.55)
	_list.add_child(hint)
