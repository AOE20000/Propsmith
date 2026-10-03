"""SiroinoSotai (CC0) FBX -> VRM 1.0 baseline body.

Pipeline: import FBX -> scale to target height -> ground the feet at z=0 ->
drop the zero-delta separator "shape keys" -> fill the VRM 1.0 humanoid mapping
-> export .vrm.

Run with the project toolchain (the VRM addon lives there):
  D:/workbuddy/blender-4.2.23/blender-4.2.23-windows-x64/blender.exe \
      --background --python vendor/models/export_base_vrm.py
"""
import os
import addon_utils
import bpy
from mathutils import Vector

SRC = r"D:/untitled/FPGames/vendor/models/SiroinoSotai_1.0/SiroinoSotai_PC.fbx"
OUT = r"D:/untitled/FPGames/vendor/models/build/base_female.vrm"
BODY = "SiroinoSotai_PC"

# --- scale policy -------------------------------------------------------------
# This 素体 has **no head**: 22 of 8,421 vertices sit above the neck joint, forming
# a 4.7 cm neck stub. "Measured height" is therefore foot→neck, not a person's
# height, and scaling that to a nominal height overshoots badly as soon as a head
# is attached (the first attempt scaled it to 1.70 m of *body*, which would put
# the finished character around 2.05 m).
#
# So: keep the authored scale for now and only ground the feet. The one and only
# normalisation happens later, applied to body + head **together**, once the head
# asset is chosen — that way the head's own size, not a guessed fraction, decides
# the result. Measurements to match a head against are printed below.
BODY_SCALE = 1.0
# For the record only: what total height a body of this length implies, per head
# count. 7.5 heads is realistic, 6.0-6.5 is the stylised anime range.
HEAD_COUNTS = (7.5, 6.5, 6.0)


def log(*args):
    print("[base]", *args)


os.makedirs(os.path.dirname(OUT), exist_ok=True)
os.makedirs(r"D:/workbuddy/tmp", exist_ok=True)
# C: had 100 MB free; keep every scratch file off it.
bpy.context.preferences.filepaths.temporary_directory = r"D:/workbuddy/tmp"

bpy.ops.wm.read_homefile(use_empty=True)
# `read_factory_settings` would reset preferences and therefore DISABLE every
# user addon — including io_scene_vrm, whose property groups (`vrm_addon_extension`)
# only exist while it is registered. Keep user prefs, then make sure it is on.
try:
    addon_utils.enable("io_scene_vrm", default_set=True, persistent=True)
except Exception as exc:  # noqa: BLE001
    log("VRM addon enable failed:", exc)
log("vrm addon registered:", hasattr(bpy.types.Armature, "vrm_addon_extension"))

bpy.ops.import_scene.fbx(filepath=SRC)

mesh = bpy.data.objects[BODY]
arm = next(o for o in bpy.data.objects if o.type == "ARMATURE")
log("mesh=%s armature=%s parent=%s(%s)"
    % (mesh.name, arm.name, mesh.parent.name if mesh.parent else None, mesh.parent_type))

# The mesh is normally a child of the armature: scaling both would scale it twice,
# so the scaled set is the roots only, and transforms are applied to those.
if mesh.parent is not None:
    roots = [arm]
else:
    roots = [arm, mesh]


def world_bounds(objs):
    low = Vector((1e9, 1e9, 1e9))
    high = Vector((-1e9, -1e9, -1e9))
    for obj in objs:
        if obj.type != "MESH":
            continue
        for corner in obj.bound_box:
            point = obj.matrix_world @ Vector(corner)
            low = Vector((min(low[i], point[i]) for i in range(3)))
            high = Vector((max(high[i], point[i]) for i in range(3)))
    return low, high


low, high = world_bounds([mesh])
span = high.z - low.z
log("body foot->neck (no head) = %.4f m" % span)
for heads in HEAD_COUNTS:
    # head = total / heads, so body = total * (1 - 1/heads)
    log("  at %s heads, a body this long belongs to a %.3f m character"
        % (heads, span / (1.0 - 1.0 / heads)))
log("BODY_SCALE = %.4f (normalisation deferred until a head exists)" % BODY_SCALE)
for obj in roots:
    obj.scale = obj.scale * BODY_SCALE
bpy.context.view_layer.update()

if abs(BODY_SCALE - 1.0) > 1e-6:
    bpy.ops.object.select_all(action="DESELECT")
    for obj in roots:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)

low, high = world_bounds([mesh])
shift = Vector((0.0, 0.0, -low.z))
log("grounding: feet were at z=%.4f, shifting by %.4f" % (low.z, shift.z))
for obj in roots:
    obj.location = obj.location + shift
bpy.context.view_layer.update()
bpy.ops.object.select_all(action="DESELECT")
for obj in roots:
    obj.select_set(True)
bpy.context.view_layer.objects.active = arm
bpy.ops.object.transform_apply(location=True, rotation=False, scale=False)

low, high = world_bounds([mesh])
log("after: height=%.4f m  feet z=%.4f  top z=%.4f" % (high.z - low.z, low.z, high.z))

# Separator keys are zero-delta list markers, not morphs: they would waste a
# morph slot in every exported surface.
keys = mesh.data.shape_keys.key_blocks
doomed = [k.name for k in keys if k.name.startswith("_____")]
bpy.ops.object.select_all(action="DESELECT")
mesh.select_set(True)
bpy.context.view_layer.objects.active = mesh
for name in doomed:
    mesh.shape_key_remove(keys[name])
log("dropped separators:", doomed)
log("shape keys now: %d" % len(mesh.data.shape_keys.key_blocks))

# --- surface: the package ships no albedo -------------------------------------
# TEX/ contains only *Normal* maps (plus a 133 MB PSD to author the skin yourself),
# so the body arrives with a flat material. Until that PSD albedo is painted, give
# it a plain skin tone — otherwise the base body exports as a near-white mannequin.
SKIN_HEX = "#EBCBB4"


def _srgb_to_linear(channel):
    return channel / 12.92 if channel <= 0.04045 else ((channel + 0.055) / 1.055) ** 2.4


def _paint(colour_hex, roughness=0.55):
    text = colour_hex.lstrip("#")
    # Principled "Base Color" is **linear**; the glTF exporter copies it straight
    # into baseColorFactor, and Godot then re-encodes it to sRGB for
    # `albedo_color`. Feeding the hex's sRGB numbers in raw therefore lands a
    # shade too light (0.92,0.80,0.71 came back as 0.965,0.904,0.858) — convert.
    rgba = tuple(_srgb_to_linear(int(text[i:i + 2], 16) / 255.0) for i in (0, 2, 4)) + (1.0,)
    for material in bpy.data.materials:
        if not material.use_nodes or material.node_tree is None:
            continue
        for node in material.node_tree.nodes:
            if node.type == "TEX_IMAGE" and node.image is not None:
                for socket in node.outputs:
                    for link in socket.links:
                        log("  image %s -> %s.%s"
                            % (node.image.name, link.to_node.name, link.to_socket.name))
            if node.type == "BSDF_PRINCIPLED":
                node.inputs["Base Color"].default_value = rgba
                node.inputs["Roughness"].default_value = roughness
        log("painted %s with %s" % (material.name, colour_hex))


_paint(SKIN_HEX)

# VRM 1.0 humanoid mapping. Names come from the asset's own rig (Unity Humanoid
# style, _L/_R suffixes) — mapped explicitly rather than by suffix heuristics,
# because "_L" means "left" on the rig but "Large" on the body shape keys.
BONES = {
    "hips": "Hips", "spine": "Spine", "chest": "Chest", "neck": "Neck", "head": "Head",
    "leftShoulder": "Shoulder_L", "rightShoulder": "Shoulder_R",
    "leftUpperArm": "UpperArm_L", "leftLowerArm": "LowerArm_L", "leftHand": "Hand_L",
    "rightUpperArm": "UpperArm_R", "rightLowerArm": "LowerArm_R", "rightHand": "Hand_R",
    "leftUpperLeg": "UpperLeg_L", "leftLowerLeg": "LowerLeg_L",
    "leftFoot": "Foot_L", "leftToes": "Toe_L",
    "rightUpperLeg": "UpperLeg_R", "rightLowerLeg": "LowerLeg_R",
    "rightFoot": "Foot_R", "rightToes": "Toe_R",
}

ext = arm.data.vrm_addon_extension
try:
    human_bones = ext.vrm1.humanoid.human_bones
except AttributeError as exc:
    log("EXT_FAIL: vrm1 extension not on armature data:", exc)
    raise

human_bones.initial_automatic_bone_assignment = False
human_bones.filter_by_human_bone_hierarchy = False
lookup = {}
for name, prop in human_bones.human_bone_name_to_human_bone().items():
    lookup[getattr(name, "value", str(name))] = prop

present = {b.name for b in arm.data.bones}
assigned = 0
for slot, bone in BONES.items():
    prop = lookup.get(slot)
    if prop is None:
        log("  !! slot not exposed by this addon version:", slot)
        continue
    if bone not in present:
        log("  !! bone absent from armature:", bone)
        continue
    prop.node.bone_name = bone
    assigned += 1
log("humanoid mapped %d/%d" % (assigned, len(BONES)))

try:
    meta = ext.vrm1.meta
    meta.title = "Propsmith base body (female)"
    meta.author = "Propsmith"
    meta.license_name = "CC0"
    log("meta: title=%s license=%s" % (meta.title, meta.license_name))
except Exception as exc:  # noqa: BLE001
    log("META_FAIL:", exc)

bpy.ops.object.select_all(action="DESELECT")
arm.select_set(True)
mesh.select_set(True)
bpy.context.view_layer.objects.active = arm

kwargs = {
    "filepath": OUT,
    "armature_object_name": arm.name,
    "ignore_warning": False,
    # Plain (non-sparse) morph data: Godot's glTF importer is the consumer, and
    # sparse accessors are the riskier of the two encodings.
    "export_try_sparse_sk": False,
}
try:
    bpy.ops.export_scene.vrm(**kwargs)
    log("EXPORT OK ->", OUT)
except Exception as exc:  # noqa: BLE001
    log("EXPORT_FAIL:", exc)

if os.path.exists(OUT):
    log("size: %.1f MB" % (os.path.getsize(OUT) / 1048576))
