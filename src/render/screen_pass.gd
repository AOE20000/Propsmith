extends MeshInstance3D
class_name ScreenPass
## A full-screen shader pass that follows whatever camera is currently active.
##
## Two constraints shape this, and both were discovered rather than assumed:
##
##   1. **It has to be in the 3D pipeline.** A `canvas_item` overlay is the
##      obvious place for a screen-space effect, and it cannot read the depth
##      buffer — `hint_depth_texture` is not available to canvas shaders, and the
##      shader silently fails to compile. Depth is what draws the ink line around
##      a silhouette, so the pass lives on a quad in the 3D scene instead.
##   2. **It has to follow the camera, not be welded to one.** This project swaps
##      cameras freely — the player rig, the debug free camera, a vehicle seat —
##      and a pass parented to one camera disappears the moment the player looks
##      through another. So the quad is `top_level` and positions itself every
##      frame in front of `Viewport.get_camera_3d()`.
##
## Sized from the camera's frustum each frame rather than once at creation, so a
## field-of-view change or a window resize keeps the pass covering the frame.

## How far in front of the near plane the quad sits. It only has to clear the near
## plane so its vertices are not clipped; with depth testing off, how far away it
## is has no effect on the image.
const NEAR_OFFSET: float = 0.05

## Uniform a pass may declare to receive the size of one screen pixel:
##
##     uniform vec2 screen_pixel_size = vec2(0.0007);
##
## Pushed from here rather than read in the shader because no spatial builtin
## exposes it — `SCREEN_PIXEL_SIZE` belongs to canvas shaders — and a screen-space
## pass needs it to take one-pixel steps. Optional: a shader that does not declare
## it is left alone, since setting an undeclared parameter is an engine error
## rather than a no-op.
const PIXEL_SIZE_UNIFORM: StringName = &"screen_pixel_size"

var quad: QuadMesh = null

## Resolved once. `Shader.get_shader_uniform_list()` is not free and this is asked
## on the first frame of the pass's life, not every frame.
var _wants_pixel_size: bool = false


func _ready() -> void:
	# Detached from the parent's transform: this node places itself in world space
	# from the camera, and inheriting the director's transform would double it.
	top_level = true
	# Hand-placed every frame from the camera transform; physics interpolation
	# would tear it off the camera it is meant to hug.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	# Frustum culling judges from the mesh's own bounds while this mesh is placed
	# by hand every frame. A margin larger than any scene keeps it out of the
	# culler's hands entirely, which is cheaper than asserting it every frame.
	extra_cull_margin = 16384.0
	if quad == null:
		quad = QuadMesh.new()
		mesh = quad
	_wants_pixel_size = _material_declares(PIXEL_SIZE_UNIFORM)


func _process(_delta: float) -> void:
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null:
		visible = false
		return
	visible = true
	var distance: float = maxf(camera.near * 2.0, NEAR_OFFSET)
	var basis: Basis = camera.global_transform.basis
	# The quad's face normal is +Z and the camera looks down -Z, so giving it the
	# camera's own basis puts its front towards the lens.
	global_transform = Transform3D(basis, camera.global_position - basis.z * distance)
	_fit(camera, distance)


## Cover the frustum at `distance`. `fov` is vertical under `KEEP_HEIGHT` and
## horizontal under `KEEP_WIDTH`, and using it the wrong way round is a pass that
## fills the frame at 16:9 and leaves bars at any other shape.
func _fit(camera: Camera3D, distance: float) -> void:
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	if viewport_size.y <= 0.0:
		return
	if _wants_pixel_size:
		var material := material_override as ShaderMaterial
		if material != null:
			material.set_shader_parameter(PIXEL_SIZE_UNIFORM, Vector2.ONE / viewport_size)
	var aspect: float = viewport_size.x / viewport_size.y
	var half_extent: float = tan(deg_to_rad(camera.fov) * 0.5) * distance
	var height: float
	var width: float
	if camera.keep_aspect == Camera3D.KEEP_WIDTH:
		width = half_extent * 2.0
		height = width / aspect
	else:
		height = half_extent * 2.0
		width = height * aspect
	quad.size = Vector2(width, height)


func _material_declares(uniform_name: StringName) -> bool:
	var material := material_override as ShaderMaterial
	if material == null or material.shader == null:
		return false
	for entry: Dictionary in material.shader.get_shader_uniform_list():
		if StringName(entry.get("name", "")) == uniform_name:
			return true
	return false
