"""茜犬-Akane- (CC0, BOOTH 8861598) -> VRM 1.0 base figure.

Akane is a complete VRChat avatar built on **SiroinoSotai v1.0 PC** — the same
素体 this project already uses — so her head is already fitted, rigged to the
same armature and scaled to the same neck. That makes "port the head" a
non-problem: the head is a separate mesh (`Body`), the bare body is a separate
mesh (`SiroinoSotai_PC`), and every garment and hair piece is separate too. The
job is therefore subtraction, not mesh surgery:

    keep   SiroinoSotai_PC  8,435 v / 16,732 tri / 102 morphs   the bare body
    keep   Body             4,077 v /  6,754 tri / 268 morphs   the head
    drop   C_* × 9          arm cover, jacket, inner, leg cover, leg ring,
                            sandal, seal, underwear, hairpin
    drop   Hair_* × 4 + dog_ear

The kept pair carries everything the pipeline needs: the 素体's whole shape-key
set (44 `*_OFF` hide-under-clothes keys, 27 body-shape keys, heels, nails — plus
two extras, `nipple` and `tendons`), the head's expression set, and — unlike the
bare 素体 package, which ships only a normal map — **real albedo textures**
(`EX3_Body2(SiroinoSotai).png` for the body, `EX3_Body1.png` for the head).

Three things the FBX needs help with:

1. **Textures.** The FBX stores the author's absolute paths
   (`D:\\モデリング\\完成\\...`), so every image loads as a 0×0 placeholder. They are
   remapped here by file name against `vendor/models/akane/TEX/` (plus the 素体's
   own TEX folder for its normal map).
2. **Scale.** Authored bare height is 1.333 m (feet at z=0.039, head top 1.372).
   The game's conventions are a 1.8 m player capsule and 1.5 m citizen capsules,
   so the base is normalised to TARGET_HEIGHT once, here, on the finished
   body+head — the moment the earlier "defer normalisation until a head exists"
   note was waiting for.
3. **Separator keys.** `_____*` and `_more_` are list markers with no delta; they
   would each cost a morph slot in every exported surface.

Run with the project toolchain (the VRM addon lives there):
  D:/workbuddy/blender-4.2.23/blender-4.2.23-windows-x64/blender.exe \
      --background --python tools/models/export_akane_vrm.py
"""
import os

import addon_utils
import bpy
from mathutils import Vector

SRC = r"D:/untitled/FPGames/vendor/models/akane/FBX/PC_akane.fbx"
OUT = r"D:/untitled/FPGames/vendor/models/build/base_female.vrm"

KEEP = ("SiroinoSotai_PC", "Body")

# Texture search roots, in order. The first covers Akane's own maps; the second
# supplies the 素体 normal map that her body material still references.
TEX_DIRS = (
    r"D:/untitled/FPGames/vendor/models/akane/TEX",
    r"D:/untitled/FPGames/vendor/models/akane/TEX/mask",
    r"D:/untitled/FPGames/vendor/models/SiroinoSotai_1.0/TEX/PC",
    r"D:/untitled/FPGames/vendor/models/SiroinoSotai_1.0/TEX/Mobail",
)

# Finished height of body+head, in metres. The game's player capsule is 1.8 m and
# its citizen capsules 1.5 m; 1.6 m sits between them and is what the CC0 素体's
# proportions suit. Configura's `body_height` DeformOption moves it from here
# (see docs/local/customization_mechanisms.md), so this is a base, not a ceiling.
TARGET_HEIGHT = 1.60

# Drop these: zero-delta list markers, not deformations.
SEPARATOR_PREFIX = "_____"
SEPARATOR_EXACT = ("_more_",)


def log(*args):
    print("[akane]", *args)


os.makedirs(os.path.dirname(OUT), exist_ok=True)
os.makedirs(r"D:/workbuddy/tmp", exist_ok=True)
# C: is the scarce drive; keep every scratch file off it.
bpy.context.preferences.filepaths.temporary_directory = r"D:/workbuddy/tmp"

bpy.ops.wm.read_homefile(use_empty=True)
# `read_factory_settings` resets preferences and would therefore disable every
# user addon, including io_scene_vrm (whose property groups only exist while it
# is registered). Keep user prefs, then make sure it is enabled.
try:
    addon_utils.enable("io_scene_vrm", default_set=True, persistent=True)
except Exception as exc:  # noqa: BLE001
    log("VRM addon enable failed:", exc)
log("vrm addon registered:", hasattr(bpy.types.Armature, "vrm_addon_extension"))
if not hasattr(bpy.types.Armature, "vrm_addon_extension"):
    raise SystemExit("io_scene_vrm is not available — export cannot proceed")

bpy.ops.import_scene.fbx(filepath=SRC)

# --- 1. textures --------------------------------------------------------------
# FBX image datablocks carry the authoring machine's absolute paths. Match them
# to our copies by file name; try the stored name, then the datablock name with
# a .png suffix (the hair map's datablock is "EX3_Hair" but the file is
# "EX3_hair.png").
available = {}
for root in TEX_DIRS:
    if not os.path.isdir(root):
        continue
    for name in os.listdir(root):
        available.setdefault(name.lower(), os.path.join(root, name))

log("texture pool: %d files across %d roots" % (len(available), len(TEX_DIRS)))
fixed, missing = 0, []
for image in bpy.data.images:
    if image.size[0] != 0 and image.size[1] != 0:
        continue
    candidates = []
    if image.filepath:
        candidates.append(os.path.basename(image.filepath).lower())
    candidates.append((image.name + ".png").lower())
    candidates.append(image.name.lower())
    hit = next((available[c] for c in candidates if c in available), None)
    if hit is None:
        missing.append(image.name)
        continue
    image.filepath = hit
    image.reload()
    ok = image.size[0] > 0
    log("  %-34s <- %s  %sx%s" % (image.name, os.path.basename(hit),
                                  image.size[0], image.size[1]))
    fixed += 1 if ok else 0
log("textures resolved: %d, unresolved: %s" % (fixed, missing or "none"))

# --- 2. strip garments and hair ----------------------------------------------
arm = next(o for o in bpy.data.objects if o.type == "ARMATURE")
kept, dropped = [], []
for obj in sorted(bpy.data.objects, key=lambda o: o.name):
    if obj.type != "MESH":
        continue
    if obj.name in KEEP:
        kept.append(obj)
    else:
        dropped.append(obj.name)
for name in dropped:
    bpy.data.objects.remove(bpy.data.objects[name], do_unlink=True)
log("kept meshes: %s" % [o.name for o in kept])
log("dropped meshes: %s" % dropped)

# --- 3. separator shape keys --------------------------------------------------
for obj in kept:
    keys = obj.data.shape_keys
    if keys is None:
        continue
    # Index through `key_blocks` — indexing the Key datablock itself with a
    # string raises KeyError.
    blocks = keys.key_blocks
    doomed = [k.name for k in blocks
              if k.name.startswith(SEPARATOR_PREFIX) or k.name in SEPARATOR_EXACT]
    for name in doomed:
        obj.shape_key_remove(blocks[name])
    log("%s: dropped %d separators -> %d shape keys"
        % (obj.name, len(doomed), len(obj.data.shape_keys.key_blocks)))


# --- 4. normalise scale, then ground -----------------------------------------
def world_bounds(objs):
    low = Vector((1e9, 1e9, 1e9))
    high = Vector((-1e9, -1e9, -1e9))
    for obj in objs:
        for corner in obj.bound_box:
            point = obj.matrix_world @ Vector(corner)
            low = Vector((min(low[i], point[i]) for i in range(3)))
            high = Vector((max(high[i], point[i]) for i in range(3)))
    return low, high


# The meshes are children of the armature, so scaling both would scale twice:
# only roots get the transform, and it is applied so the rig stays at unit scale.
roots = [o for o in bpy.data.objects if o.parent is None and o.type in ("ARMATURE", "MESH")]

low, high = world_bounds(kept)
span = high.z - low.z
factor = TARGET_HEIGHT / span
log("authored body+head height = %.4f m (feet z=%.4f)  -> scale x%.4f"
    % (span, low.z, factor))
for obj in roots:
    obj.scale = obj.scale * factor
bpy.context.view_layer.update()

bpy.ops.object.select_all(action="DESELECT")
for obj in roots:
    obj.select_set(True)
bpy.context.view_layer.objects.active = arm
bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)

low, high = world_bounds(kept)
shift = Vector((0.0, 0.0, -low.z))
log("grounding: feet at z=%.4f -> shifting by %.4f" % (low.z, shift.z))
for obj in roots:
    obj.location = obj.location + shift
bpy.context.view_layer.update()
bpy.ops.object.select_all(action="DESELECT")
for obj in roots:
    obj.select_set(True)
bpy.context.view_layer.objects.active = arm
bpy.ops.object.transform_apply(location=True, rotation=False, scale=False)

low, high = world_bounds(kept)
log("after: height=%.4f m  feet z=%.4f  top z=%.4f" % (high.z - low.z, low.z, high.z))
_, head_top = world_bounds([bpy.data.objects["Body"]])
log("head top z=%.4f (hair adds more once equipped)" % head_top.z)

# --- 5. VRM 1.0 humanoid mapping ---------------------------------------------
# Names come from the rig's own convention (Unity Humanoid style, _L/_R). Two
# bones are deliberately absent: the *_Twist_* roll bones (VRM has no slot) and
# the breast bones (VRM 1.0 has no slot either — they are expression targets in
# VRM 0.x only). Fingers are skipped for now: nothing in the game animates them
# individually, and half-mapping VRM 1.0's thumbMetacarpal/Proximal/Distal onto
# this rig's Proximal/Intermediate/Distal would silently drop a joint.
BONES = {
    "hips": "Hips", "spine": "Spine", "chest": "Chest", "neck": "Neck", "head": "Head",
    "leftEye": "Eye.L", "rightEye": "Eye.R",
    "leftShoulder": "Shoulder_L", "rightShoulder": "Shoulder_R",
    "leftUpperArm": "UpperArm_L", "leftLowerArm": "LowerArm_L", "leftHand": "Hand_L",
    "rightUpperArm": "UpperArm_R", "rightLowerArm": "LowerArm_R", "rightHand": "Hand_R",
    "leftUpperLeg": "UpperLeg_L", "leftLowerLeg": "LowerLeg_L",
    "leftFoot": "Foot_L", "leftToes": "Toe_L",
    "rightUpperLeg": "UpperLeg_R", "rightLowerLeg": "LowerLeg_R",
    "rightFoot": "Foot_R", "rightToes": "Toe_R",
}

ext = arm.data.vrm_addon_extension
human_bones = ext.vrm1.humanoid.human_bones
human_bones.initial_automatic_bone_assignment = False
human_bones.filter_by_human_bone_hierarchy = False
lookup = {}
for name, prop in human_bones.human_bone_name_to_human_bone().items():
    lookup[getattr(name, "value", str(name))] = prop

present = {b.name for b in arm.data.bones}
assigned, absent_bone, absent_slot = 0, [], []
for slot, bone in BONES.items():
    prop = lookup.get(slot)
    if prop is None:
        absent_slot.append(slot)
        continue
    if bone not in present:
        absent_bone.append("%s(%s)" % (slot, bone))
        continue
    prop.node.bone_name = bone
    assigned += 1
log("humanoid mapped %d/%d  slots-missing=%s  bones-missing=%s"
    % (assigned, len(BONES), absent_slot or "none", absent_bone or "none"))

# --- 6. expressions ----------------------------------------------------------
# The head carries 268 morphs, mostly VRChat visemes and face-editing helpers.
# Six of them map onto VRM presets one-to-one, and a VRM whose blink/visemes are
# declared is usable by any VRM-aware reader (and by Godot tooling that looks for
# the standard names). Everything else stays reachable by shape-key name through
# Configura's BlendshapeOption, which does not need a VRM declaration.
#
# Note the spelling: the head's keys are `vrc.v.e` / `vrc.v.ih` / `vrc.v.oh` /
# `vrc.v.ou` (VRChat's single-letter visemes), while VRM calls the same sounds
# `ee` / `ih` / `oh` / `ou`.
EXPRESSION_MAP = {
    "blink": "blink",
    "aa": "vrc.v.aa",
    "ih": "vrc.v.ih",
    "ou": "vrc.v.ou",
    "ee": "vrc.v.e",
    "oh": "vrc.v.oh",
}
head_obj = bpy.data.objects.get("Body")
if head_obj is not None and head_obj.data.shape_keys is not None:
    key_names = {k.name for k in head_obj.data.shape_keys.key_blocks}
    preset = ext.vrm1.expressions.preset
    bound, skipped = [], []
    for slot, key_name in EXPRESSION_MAP.items():
        expression = getattr(preset, slot, None)
        if expression is None:
            skipped.append("%s(no slot)" % slot)
            continue
        if key_name not in key_names:
            skipped.append("%s(no key %s)" % (slot, key_name))
            continue
        # Rebuild from scratch so re-runs do not stack duplicate binds.
        while len(expression.morph_target_binds) > 0:
            expression.morph_target_binds.remove(expression.morph_target_binds[0])
        bind = expression.morph_target_binds.add()
        # `bind.node` is a read-only pointer to a MeshObjectPropertyGroup; the
        # writable field is the mesh reference inside it. `index` is the *shape
        # key name*, not a number — the exporter looks it up in the target's
        # morph-target name list and silently drops the bind if it is absent.
        bind.node.bpy_object = head_obj
        bind.index = key_name
        bind.weight = 1.0
        bound.append("%s<-%s" % (slot, key_name))
    log("expressions bound: %s" % (bound or "none"))
    if skipped:
        log("expressions skipped: %s" % skipped)
else:
    log("expressions skipped: no head mesh / no shape keys")

# --- 7. meta: the asset is CC0, and the licence travels with the file --------
# This addon version has no `license_url` field: VRM 1.0 derives the standard
# licence from the four fields below, so a self-consistent set is what makes the
# file declare CC0 downstream.
meta = ext.vrm1.meta
try:
    meta.vrm_name = "Propsmith base figure (Akane head / SiroinoSotai body)"
    meta.version = "1.0"
    meta.authors.clear()
    meta.authors.add().value = "山野重工赤山派閥独立支部 (body: しろいの)"
    meta.copyright_information = "CC0 1.0 Universal (public domain dedication)"
    meta.third_party_licenses = ("Akane: 山野重工赤山派閥独立支部, CC0. "
                                 "SiroinoSotai body: しろいの, CC0. "
                                 "VRChat SDK / lilToon referenced by the source unitypackage "
                                 "are NOT included and NOT covered by CC0.")
    meta.avatar_permission = "everyone"
    meta.commercial_usage = "corporation"
    meta.credit_notation = "unnecessary"
    meta.allow_redistribution = True
    meta.modification = "allowModificationRedistribution"
    meta.other_license_url = "https://booth.pm/ja/items/8861598"
    log("meta: name=%s authors=%d CC0/everyone/corporation/redistribute"
        % (meta.vrm_name, len(meta.authors)))
except Exception as exc:  # noqa: BLE001
    log("META_PARTIAL:", exc)

# --- 8. name the two meshes --------------------------------------------------
# The FBX calls the head's mesh datablock "平面" (plane) and the body's
# "<name>_Mesh"; those strings are what a glTF reader sees, and "Body" as the
# node name for a head is actively misleading. Renamed last, so the code above
# can keep using the asset's own object names.
RENAMES = {"Body": "Akane_Head", "SiroinoSotai_PC": "SiroinoSotai_Body"}
for old, new in RENAMES.items():
    obj = bpy.data.objects.get(old)
    if obj is None:
        continue
    obj.name = new
    obj.data.name = new
    log("renamed %s -> %s" % (old, new))

# --- 9. export ----------------------------------------------------------------
bpy.ops.object.select_all(action="DESELECT")
for obj in kept:
    obj.select_set(True)
arm.select_set(True)
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
