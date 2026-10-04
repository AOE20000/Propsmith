extends RefCounted
class_name BlendSection
## The shape-key editor section of the wardrobe panel, as a self-contained
## component: row building, the working parameter set, mode routing and the
## journal flush all live here, so the panel keeps only mode-agnostic UI glue.
##
## Two modes, routed by whether an NPC target is set:
##   * **NPC edit** (`set_npc_target`): rows drive that figure's
##     `ModelBlendShapes` directly. A drag previews locally (no journaling —
##     decision payloads must be self-contained, so per-tick emits would flood
##     the journal); releasing the slider, a toggle, or the flush journals the
##     whole working set as one `set_npc_figure` decision.
##   * **Player mode** (no target): writes route through the panel's player
##     callbacks (`on_player_write`), values sync from the player state.
##
## The section reads its starting point from the *live* mesh
## (`ModelBlendShapes.current_values`), so the seeded roll and any prior
## override — whatever produced the current look — are preserved on edit.

## Called in player mode for every write: (option_id, value).
var on_player_write: Callable
## Called in player mode on sync: () -> Dictionary (the player's values).
var on_player_values: Callable

var _rows: VBoxContainer = null
var _sliders: Dictionary = {}
var _toggles: Dictionary = {}
var _built: bool = false
var _target: ModelBlendShapes = null
var _seed: int = 0
var _working: Dictionary = {}
var _dirty: bool = false


func _init(rows: VBoxContainer, player_write: Callable, player_values: Callable) -> void:
	_rows = rows
	# The parameters are named differently from the members on purpose: a parameter
	# shadows its member in GDScript, so `on_player_write = on_player_write` here
	# assigned the parameter to itself and left the member an invalid callable —
	# every manual slider/toggle in player mode silently did nothing, while the
	# panel's own randomize/reset buttons (which route through the controller, not
	# through these callables) kept working. Same shape of bug as forgetting `self.`,
	# and just as invisible until something downstream checks `is_valid()`.
	on_player_write = player_write
	on_player_values = player_values


func has_target() -> bool:
	return _target != null


## Bind the panel's row container. The panel constructs this section before
## `_build()` creates the column, so rows arrive in a second step.
func attach_rows(rows: VBoxContainer) -> void:
	_rows = rows


## Build the rows into the panel's column. The panel decides *when* (it owns
## the mode and the gate — see `CharacterPanel._blend_target`); this only owns
## the rows, the routing and the working set.
func ensure_built() -> void:
	if _built:
		return
	_built = true
	var header := Label.new()
	header.text = "形体（形状键，实时生效）"
	header.modulate = Color(0.7, 0.78, 0.88)
	_rows.add_child(header)
	for group_id: StringName in ModelBlendShapes.SLIDER_GROUPS:
		var group: Dictionary = ModelBlendShapes.SLIDER_GROUPS[group_id]
		for slider: Dictionary in group["sliders"]:
			_rows.add_child(_build_slider_row(group, slider))
	for group_id: StringName in ModelBlendShapes.TOGGLE_GROUPS:
		var group: Dictionary = ModelBlendShapes.TOGGLE_GROUPS[group_id]
		for toggle: Dictionary in group["toggles"]:
			_rows.add_child(_build_toggle_row(group, toggle))


## Point the section at a citizen's figure (NPC edit mode).
func set_npc_target(target: ModelBlendShapes, seed_key: int) -> void:
	_target = target
	_seed = seed_key
	_working = target.current_values()
	_dirty = false


## Return to player mode; unflushed NPC edits are journaled first.
func clear_npc_target() -> void:
	flush()
	_target = null


## Push the current values into every row.
func sync() -> void:
	var state := _state()
	for option_id: String in _sliders:
		var row: Dictionary = _sliders[option_id]
		var slider: HSlider = row["slider"]
		var readout: Label = row["readout"]
		var value := clampf(float(state.get(option_id, row["default"])), 0.0, 1.0)
		slider.set_value_no_signal(value)
		readout.text = "%d%%" % roundi(value * 100.0)
	for option_id: String in _toggles:
		var row: Dictionary = _toggles[option_id]
		var checkbox: CheckBox = row["checkbox"]
		checkbox.set_pressed_no_signal(bool(state.get(option_id, row["default"])))


## Slider drag: preview locally in NPC mode; the release journals (see
## `_release_slider`). Player mode routes through the panel callback.
func set_value(option_id: String, value: float) -> void:
	if _target != null:
		_working[option_id] = value
		_dirty = true
		_target.apply_values(_working)
		return
	if on_player_write.is_valid():
		on_player_write.call(option_id, value)


## Toggle flip: a single action, so the NPC path journals immediately.
func set_toggle(option_id: String, on: bool) -> void:
	if _target != null:
		_working[option_id] = on
		_target.apply_values(_working)
		NpcFigure.emit_figure_override(_seed, _working)
		_dirty = false
		return
	if on_player_write.is_valid():
		on_player_write.call(option_id, on)


## A fresh randomized look for the NPC under edit, emitted as a decision.
func randomize_npc_look() -> void:
	if _target == null:
		return
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	_working = ModelBlendShapes.randomized_values(rng)
	_target.apply_values(_working)
	NpcFigure.emit_figure_override(_seed, _working)
	_dirty = false


## The authored body for the NPC under edit, emitted as a decision.
func reset_npc_look() -> void:
	if _target == null:
		return
	_working = ModelBlendShapes.default_values()
	_target.apply_values(_working)
	NpcFigure.emit_figure_override(_seed, _working)
	_dirty = false


## Journal the working set if it changed and was not flushed yet (slider
## release calls this too; the panel calls it when the panel closes).
func flush() -> void:
	if _target == null or not _dirty:
		return
	NpcFigure.emit_figure_override(_seed, _working)
	_dirty = false


## The parameter dictionary rows read on sync: the NPC working set, or the
## player's state via the panel callback.
func _state() -> Dictionary:
	if _target != null:
		return _working
	if on_player_values.is_valid():
		return on_player_values.call()
	return {}


func _build_slider_row(group: Dictionary, slider: Dictionary) -> HBoxContainer:
	var option_id := String(slider["id"])
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.add_child(_label("%s·%s" % [group["label"], slider["label"]]))

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
		set_value(option_id, value)
	)
	control.drag_ended.connect(func(_changed: bool) -> void:
		flush()
	)
	_sliders[option_id] = {
		"slider": control, "readout": readout, "default": float(slider["default"]),
	}
	return row


func _build_toggle_row(group: Dictionary, toggle: Dictionary) -> HBoxContainer:
	var option_id := String(toggle["id"])
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.add_child(_label("%s·%s" % [group["label"], toggle["label"]]))

	var checkbox := CheckBox.new()
	checkbox.button_pressed = bool(toggle["default"])
	checkbox.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	row.add_child(checkbox)

	checkbox.toggled.connect(func(on: bool) -> void:
		set_toggle(option_id, on)
	)
	_toggles[option_id] = {"checkbox": checkbox, "default": bool(toggle["default"])}
	return row


func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(110.0, 0.0)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return label
