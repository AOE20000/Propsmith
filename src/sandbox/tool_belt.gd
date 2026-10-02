extends Node
class_name ToolBelt
## Which tool the player is holding. Registered as the `tool_belt` service and
## wired into the tree so it can listen for the switch keys.
##
## The belt is the answer to "the same mouse button means different things":
## the attack controller checks the belt before swinging, the wrench only wakes
## up when it is the held tool, and the HUD can display what is in hand. Tools
## are registered by id (&"weapon", &"wrench", and later the tool gun) — a mod
## that adds a tool joins this list rather than inventing its own input scheme.

const TOOLS: Array[StringName] = [&"weapon", &"wrench"]

var current: StringName = &"weapon"


func switch_to(tool_id: StringName) -> void:
	if tool_id == current or not TOOLS.has(tool_id):
		return
	current = tool_id
	Events.hand_tool_changed.emit(current)
	Events.notify("手持：%s" % display_name_for(current), Events.NotifyLevel.INFO)


func toggle() -> void:
	var index: int = TOOLS.find(current)
	switch_to(TOOLS[(index + 1) % TOOLS.size()])


func display_name_for(tool_id: StringName) -> String:
	match tool_id:
		&"weapon": return "武器"
		&"wrench": return "物理扳手"
	return String(tool_id)


func _unhandled_input(event: InputEvent) -> void:
	if GameState.mode != GameState.Mode.EXPLORING:
		return
	if event.is_action_pressed(&"tool_wrench"):
		switch_to(&"wrench")
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"tool_weapon"):
		switch_to(&"weapon")
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"undo"):
		# Global undo belongs to the belt (not to any one tool): the last
		# spawn goes away no matter which tool is in hand.
		var spawner: PropSpawner = Services.get_as(&"prop_spawner", &"PropSpawner") as PropSpawner
		if spawner != null and spawner.undo():
			Events.notify("已撤销上一次生成", Events.NotifyLevel.INFO)
		get_viewport().set_input_as_handled()
