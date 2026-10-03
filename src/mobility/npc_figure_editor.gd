extends Interactable
class_name NpcFigureEditor
## The E-handle on a citizen: looking at one and pressing interact opens the
## wardrobe panel in NPC mode, aimed at that citizen's figure.
##
## Composed as a child of the agent (the agent's base class is taken), per the
## Interactable contract. The panel is found through the `character_panel`
## group rather than a node path — boot order owns the panel, this file owns
## the intent.
##
## The agent reference is deliberately untyped: `PedestrianAgent` (its owner)
## holds a typed `NpcFigureEditor`, and a typed back-reference would close a
## class_name cycle that Godot's parser cannot resolve (the same trap the
## ModContext/ScriptBridge split solved).

var agent = null


func _init() -> void:
	verb = "编辑外观"


func interact(_player: Node = null) -> void:
	var tree := get_tree()
	if tree == null:
		return
	for node: Node in tree.get_nodes_in_group(&"character_panel"):
		var panel := node as CharacterPanel
		if panel != null and agent != null:
			panel.open_for_npc(agent)
			return
