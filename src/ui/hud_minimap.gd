extends Control
class_name HudMinimap
## The top-right minimap: a second camera looking straight down, rendered into a
## `SubViewport` and stretched into a 2D frame.
##
## Split out of `Hud` because it is a different kind of thing from the rest of the HUD.
## Everything else there is 2D text and bars driven by `Events`; this owns a 3D camera,
## a viewport and a world binding, and it is the only part of the interface that has to
## know a 3D world exists at all.
##
## A camera beats drawing a map texture by hand: it costs nothing to keep in sync and it
## picks up landmarks and mod content for free, which is exactly what a prototype needs
## while the world is still changing shape.

## Rendered resolution, also the camera's orthographic footprint is derived from it.
const MINIMAP_SIZE: float = 220.0
const MINIMAP_HEIGHT: float = 140.0
## Thickness of the tinted frame drawn behind the viewport.
const FRAME_MARGIN: float = 4.0

var _viewport: SubViewport = null
var _camera: Camera3D = null


func _ready() -> void:
	name = "Minimap"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_TOP_RIGHT)
	var outer: float = MINIMAP_SIZE + FRAME_MARGIN * 2.0
	offset_left = -outer - 16.0
	offset_top = 16.0
	offset_right = -16.0
	offset_bottom = 16.0 + outer
	_build()

	# The world's 3D viewport exists by the time the HUD is built, but binding deferred
	# avoids depending on the order the HUD was added in.
	call_deferred("bind_world")


## The frame is a sibling *behind* the viewport container, not its parent: a
## `SubViewport` can have only one parent, and a tinted quad is easier to reason about
## than a themed panel.
func _build() -> void:
	var frame := ColorRect.new()
	frame.name = "Frame"
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.color = Color(0.86, 0.92, 1.0, 0.2)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(frame)

	var container := SubViewportContainer.new()
	container.name = "View"
	container.set_anchors_preset(Control.PRESET_FULL_RECT)
	container.offset_left = FRAME_MARGIN
	container.offset_top = FRAME_MARGIN
	container.offset_right = -FRAME_MARGIN
	container.offset_bottom = -FRAME_MARGIN
	container.stretch = true
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(container)

	_viewport = SubViewport.new()
	_viewport.size = Vector2i(int(MINIMAP_SIZE), int(MINIMAP_SIZE))
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# Not `own_world_3d`: the point is to render the game's own world.
	_viewport.own_world_3d = false
	container.add_child(_viewport)

	_camera = Camera3D.new()
	_camera.name = "MinimapCamera"
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = 260.0
	_camera.far = 600.0
	_camera.position = Vector3(0.0, MINIMAP_HEIGHT, 0.0)
	# A hair off straight down: an exactly perpendicular camera makes the view matrix
	# degenerate and the render comes back blank.
	_camera.rotation_degrees = Vector3(-89.9, 0.0, 0.0)
	_viewport.add_child(_camera)


func bind_world() -> void:
	if _viewport == null:
		return
	var world: Viewport = get_viewport()
	if world != null:
		_viewport.world_3d = world.world_3d


## Centre the view on a world position. Called by the HUD each frame with the player's
## position; a null or absent camera is a no-op so the HUD never has to check.
func follow(world_position: Vector3) -> void:
	if _camera == null:
		return
	_camera.position = Vector3(world_position.x, MINIMAP_HEIGHT, world_position.z)
