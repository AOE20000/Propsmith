extends Area3D
class_name PoiMarker
## A discoverable landmark. Discovery is the exploration reward loop: entering the
## marker's radius records the POI once, notifies the HUD, and grants its reward.
##
## The geometry a mod registers is arbitrary; this node only owns identity,
## the discovery trigger, and the one-shot rule. The five built-in shapes live in
## `PoiGeometry`, which is where a mod author writing an `add_poi_factory` should look.
##
## Discovery is announced on `Events.poi_discovered` and nowhere else. A node-scoped
## `discovered` signal used to exist as well; it was removed because nothing connected
## to it and having two announcement paths for one fact contradicts the project's rule
## that the event bus is the single broadcast seam.

var poi_id: StringName = &"poi"
var display_name: String = "无名地标"
var discover_radius: float = 14.0
var reward_item_id: StringName = &""
var reward_amount: int = 0

var _discovery_shape: CollisionShape3D = null


func configure(id: StringName, title: String, radius: float) -> void:
	poi_id = id
	display_name = title
	discover_radius = radius


func _ready() -> void:
	# An `Area3D` that watches the world layer and is itself invisible to it: a
	# landmark must notice the player without becoming something the player can bump.
	collision_layer = 0
	collision_mask = 1
	monitoring = true
	monitorable = false

	var sphere := SphereShape3D.new()
	sphere.radius = discover_radius
	_discovery_shape = CollisionShape3D.new()
	_discovery_shape.shape = sphere
	_discovery_shape.position = Vector3(0.0, discover_radius * 0.4, 0.0)
	add_child(_discovery_shape)

	body_entered.connect(_on_body_entered)

	# A landmark discovered in an earlier session shows as already found.
	if GameState.is_poi_discovered(poi_id):
		set_deferred("monitoring", false)


func _on_body_entered(body: Node3D) -> void:
	if not body.is_in_group(&"player"):
		return
	# `mark_poi_discovered` returns false the second time, which is what makes this a
	# one-shot without a timer or a flag of our own.
	if not GameState.mark_poi_discovered(poi_id):
		return

	Events.poi_discovered.emit(poi_id, display_name, global_position)
	Events.notify("发现地标：%s" % display_name, Events.NotifyLevel.SUCCESS)
	if reward_item_id != &"" and reward_amount > 0:
		Events.collectible_picked_up.emit(reward_item_id, reward_amount)
	set_deferred("monitoring", false)
