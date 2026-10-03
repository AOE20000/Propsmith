"""The reference body (SiroinoSotai PC) wearing Akane's head — VRM 1.0.

Both halves are CC0 1.0. This replaces the earlier "use Akane's body too"
version, because measuring the two bodies settled what Akane actually changed:

    her body mesh   = the original, uniformly scaled 1.10 — |delta|/|p| is a
                      constant 0.0962..0.1025 and the angle between delta and p
                      is 0.01 deg on average (99.8% under 1 deg), so there are
                      no local edits at all (1.1426 x 1.1 = 1.2569, her top, to
                      the millimetre)
    weights/groups  = identical (57 groups, same names; 12 vertices differ by
                      <0.07 in the hip/thigh blend)
    bone rest axes  = identical, 0.00 deg of roll on all 60 shared bones
    bone rest scale = 1.0 everywhere in both rigs

The one real difference is **four bones whose tails were lengthened while their
joints stayed put**: `Head` +5.2 cm, `UpperLeg_L` +10.1 cm, `UpperLeg_R` +8.0 cm,
`Hips` +2.3 cm. Joints that no longer sit where their parent's tail is are
exactly what makes bone-length-based scaling behave inconsistently, which is the
"bone scaling bug" the reference rig does without. So: take the reference rig and
mesh, and take only her head.

Taking only the head is cheap because the head mesh has just four vertex groups
(`Head` 3259 / `Eye.L` 395 / `Eye.R` 395 / `Neck` 91), and because
`akane / 1.10 == original` the head scaled by 1/1.10 mates with the reference
neck exactly as designed — no neck extension, no reweighting. Measured in the
reference frame: the head spans z 1.0779..1.2475 and the body's neck top is
1.1426, so they already overlap by 6.5 cm.

Two things have to be supplied by hand:

  * the reference rig has **no eye bones** — `Eye.L`/`Eye.R` are copied from
    Akane's rig (divided by 1.10), parented to `Head`;
  * the reference body's material carries **only a normal map** (the 素体 package
    ships no albedo). Akane's own body material has the albedo painted for this
    exact UV, so it is carried over.

Akane's hair comes along with her head (`Hair_ahoge/back/front/side`, the same
1.10 frame and the same `EX3_Hair` atlas). Its pieces are skinned to their own
decorative chains — three roots under `Head` plus 22 chain bones — which are
copied from her rig, scaled by 1/1.10 like everything of hers, in parent-first
order. The dog ears stay out: they are an accessory, not hair, and a natural
first `MeshSwapOption`.

Run with the project toolchain (the VRM addon lives there):
  D:/workbuddy/blender-4.2.23/blender-4.2.23-windows-x64/blender.exe \
      --background --python tools/models/export_akane_vrm.py
"""
import os

import addon_utils
import bpy
from mathutils import Matrix, Vector

BODY_SRC = r"D:/untitled/FPGames/vendor/models/SiroinoSotai_1.0/SiroinoSotai_PC.fbx"
HEAD_SRC = r"D:/untitled/FPGames/vendor/models/akane/FBX/PC_akane.fbx"
OUT = r"D:/untitled/FPGames/vendor/models/build/base_female.vrm"

BODY_OBJECT = "SiroinoSotai_PC"
HEAD_OBJECT = "Body"
# Hair rides along with the head: same 1.10 frame, same EX3_Hair atlas, skinned
# mostly to its own decorative chains. The dog ears stay out — they are an
# accessory (a natural first MeshSwapOption), not hair.
HAIR_OBJECTS = ("Hair_ahoge", "Hair_back", "Hair_front", "Hair_side")

# Akane's whole rig and mesh are the reference at 1.10x. Dividing the head by
# that factor puts body and head in one frame; dividing both by the same factor
# keeps her head-to-body ratio, which is the whole point of taking her head.
AKANE_SCALE = 1.10
HEAD_SCALE = 1.0 / AKANE_SCALE

# Texture search roots, in order: Akane's own maps first, then the 素体 package
# for the normal map her body material still references.
TEX_DIRS = (
    r"D:/untitled/FPGames/vendor/models/akane/TEX",
    r"D:/untitled/FPGames/vendor/models/akane/TEX/mask",
    r"D:/untitled/FPGames/vendor/models/SiroinoSotai_1.0/TEX/PC",
    r"D:/untitled/FPGames/vendor/models/SiroinoSotai_1.0/TEX/Mobail",
)

# Finished height of body+head. The game's player capsule is 1.8 m and its
# citizen capsules 1.5 m; 1.6 m sits between them. THIS is the normalisation the
# earlier note deferred until a head existed — body+head measure 1.2122 m in the
# reference frame, so the factor here is 1.3200.
TARGET_HEIGHT = 1.60

EYE_BONES = ("Eye.L", "Eye.R")


def bake_transform(obj):
    """Fold an object's local transform into its mesh data, shape keys included.

    `bpy.ops.object.transform_apply` does **not** touch shape keys, so a mesh
    that carries morphs keeps every key at the old scale and offset — silently
    desynchronising 268 morphs from their basis. Doing it by hand keeps basis and
    keys together. The head arrives with a -2 cm Y offset, which would otherwise
    land as a 1.8 mm mismatch at the neck once the data is scaled.
    """
    matrix = obj.matrix_basis
    if matrix == Matrix.Identity(4):
        return False
    for vertex in obj.data.vertices:
        vertex.co = matrix @ vertex.co
    keys = obj.data.shape_keys
    if keys is not None:
        for block in keys.key_blocks:
            for vertex in block.data:
                vertex.co = matrix @ vertex.co
    obj.matrix_basis = Matrix.Identity(4)
    return True


def log(*args):
    print("[base]", *args)


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
if not hasattr(bpy.types.Armature, "vrm_addon_extension"):
    raise SystemExit("io_scene_vrm is not available — export cannot proceed")

# --- 1. Akane first: take the head, the eye bones and the body material ------
bpy.ops.import_scene.fbx(filepath=HEAD_SRC)
akane_armature = next(o for o in bpy.data.objects if o.type == "ARMATURE")
head = bpy.data.objects[HEAD_OBJECT]
akane_body = bpy.data.objects[BODY_OBJECT]

# The albedo for this body's UV only exists in this package; the 素体 ships a
# normal map and nothing else.
body_material = None
for slot_material in akane_body.data.materials:
    if slot_material is not None:
        body_material = slot_material
        break
log("body material taken from Akane:", body_material.name if body_material else "NONE")

eye_rest = {}
# Hair pieces ride along (see HAIR_OBJECTS). Collect every bone they reference,
# then capture them all — plus the eye bones — in edit mode, because `roll`
# only exists on EditBone: rebuilding a chain with the wrong roll would twist
# every strand around its own axis the first time the bone rotates. Uniform
# scaling preserves bone direction, so scaled head/tail + same roll reproduces
# Akane's local frames exactly and the weights carry over untouched.
hair_objects = [bpy.data.objects[name] for name in HAIR_OBJECTS]
# The vertex groups name the chain bones, but not the roots above them: a root
# (hair_back_root etc.) carries no weights yet parents the first link. Walk
# every referenced bone up to `Head` so the whole chain — roots included — gets
# captured.
wanted = set()
for obj in hair_objects:
    for group in obj.vertex_groups:
        walker = akane_armature.data.bones.get(group.name)
        while walker is not None and walker.name != "Head":
            wanted.add(walker.name)
            walker = walker.parent
wanted.discard("Head")

bpy.ops.object.select_all(action="DESELECT")
bpy.context.view_layer.objects.active = akane_armature
akane_armature.select_set(True)
bpy.ops.object.mode_set(mode="EDIT")
captured = {}
for name in sorted(wanted | set(EYE_BONES)):
    edit_bone = akane_armature.data.edit_bones.get(name)
    if edit_bone is None:
        log("!! Akane's rig has no %s" % name)
        continue
    captured[name] = (
        tuple(v / AKANE_SCALE for v in edit_bone.head),
        tuple(v / AKANE_SCALE for v in edit_bone.tail),
        edit_bone.parent.name if edit_bone.parent else "Head",
        edit_bone.roll,
    )
bpy.ops.object.mode_set(mode="OBJECT")
eye_rest = {name: captured[name] for name in EYE_BONES if name in captured}
hair_bone_rest = {name: data for name, data in captured.items() if name not in EYE_BONES}
log("eye bones captured: %s" % sorted(eye_rest))
log("hair bones captured (reference frame): %d" % len(hair_bone_rest))

log("head object transform: loc=%s scale=%s"
    % (tuple(round(v, 5) for v in head.location), tuple(round(v, 5) for v in head.scale)))
if bake_transform(head):
    log("head object transform baked into the mesh (it was not identity)")
else:
    log("head object transform was already identity")

kept_names = {head.name} | {obj.name for obj in hair_objects}
for obj in list(bpy.data.objects):
    if obj.name not in kept_names:
        bpy.data.objects.remove(obj, do_unlink=True)
log("kept from Akane: %s" % [o.name for o in bpy.data.objects])

# --- 2. the reference body ---------------------------------------------------
bpy.ops.import_scene.fbx(filepath=BODY_SRC)
armature = next(o for o in bpy.data.objects if o.type == "ARMATURE")
body = bpy.data.objects[BODY_OBJECT]
log("reference body: %s  armature: %s (%d bones)"
    % (body.name, armature.name, len(armature.data.bones)))

if body_material is not None:
    body.data.materials.clear()
    body.data.materials.append(body_material)
    log("body material replaced with %s" % body_material.name)

# --- 3. put the head in the reference frame ---------------------------------
# Scaling the mesh *data* (basis and every shape key) rather than the object:
# `transform_apply` does not touch shape keys, so scaling the object would leave
# all 268 morphs at the old scale.
def scale_shape_data(obj, factor):
    mesh = obj.data
    for vertex in mesh.vertices:
        vertex.co *= factor
    keys = mesh.shape_keys
    if keys is None:
        return 0
    for block in keys.key_blocks:
        for vertex in block.data:
            vertex.co *= factor
    return len(keys.key_blocks)


key_count = scale_shape_data(head, HEAD_SCALE)
log("head scaled by %.6f (object transform untouched); %d shape keys follow"
    % (HEAD_SCALE, key_count))

for obj in hair_objects:
    if bake_transform(obj):
        log("%s: object transform baked" % obj.name)
    keys = scale_shape_data(obj, HEAD_SCALE)
    log("%s scaled by %.6f (%d shape keys)" % (obj.name, HEAD_SCALE, keys))

# --- 4. eye bones and hair chains on the reference rig -----------------------
bpy.ops.object.select_all(action="DESELECT")
bpy.context.view_layer.objects.active = armature
armature.select_set(True)
bpy.ops.object.mode_set(mode="EDIT")
edit_bones = armature.data.edit_bones
for name, (head_pos, tail_pos, parent_name, roll) in eye_rest.items():
    if name in edit_bones:
        edit_bones.remove(edit_bones[name])
    bone = edit_bones.new(name)
    bone.head = Vector(head_pos)
    bone.tail = Vector(tail_pos)
    bone.roll = roll
    bone.parent = edit_bones[parent_name]
    bone.use_connect = False
    log("added %s to the reference rig (parent %s)" % (name, parent_name))

# Hair chains, parents first: every wanted bone hangs off `Head` directly (the
# three roots) or off another wanted bone (the chains), so a pass that skips
# not-yet-addable bones terminates.
pending = dict(hair_bone_rest)
while pending:
    progressed = False
    for name in list(pending):
        head_pos, tail_pos, parent_name, roll = pending[name]
        if parent_name != "Head" and parent_name in pending:
            continue
        if parent_name != "Head" and edit_bones.get(parent_name) is None:
            log("!! %s: parent %s unknown — attaching to Head instead"
                % (name, parent_name))
            parent_name = "Head"
        bone = edit_bones.new(name)
        bone.head = Vector(head_pos)
        bone.tail = Vector(tail_pos)
        bone.roll = roll
        bone.parent = edit_bones[parent_name]
        bone.use_connect = False
        del pending[name]
        progressed = True
    if not progressed:
        log("!! hair bone chains stuck: %s" % sorted(pending))
        break
bpy.ops.object.mode_set(mode="OBJECT")
log("reference rig now has %d bones (60 body + 2 eyes + %d hair)"
    % (len(armature.data.bones), len(hair_bone_rest)))

# --- 5. bind the head to the reference rig ---------------------------------
# The weights are already in the mesh's vertex groups and every group now exists
# on the rig, so no automatic weighting is involved — a missing group would show
# up as vertices pinned to the origin instead.
missing = [vg.name for vg in head.vertex_groups if vg.name not in armature.data.bones]
log("head vertex groups missing from the rig: %s" % (missing or "none"))
head.parent = armature
head.parent_type = "OBJECT"
head.matrix_parent_inverse = armature.matrix_world.inverted()
for modifier in list(head.modifiers):
    if modifier.type == "ARMATURE":
        head.modifiers.remove(modifier)
armature_modifier = head.modifiers.new(name="Armature", type="ARMATURE")
armature_modifier.object = armature
log("head bound to %s, modifiers=%s" % (armature.name, [m.type for m in head.modifiers]))

for obj in hair_objects:
    missing = [vg.name for vg in obj.vertex_groups if vg.name not in armature.data.bones]
    if missing:
        log("!! %s: groups missing from the rig: %s" % (obj.name, missing))
    obj.parent = armature
    obj.parent_type = "OBJECT"
    obj.matrix_parent_inverse = armature.matrix_world.inverted()
    for modifier in list(obj.modifiers):
        if modifier.type == "ARMATURE":
            obj.modifiers.remove(modifier)
    obj.modifiers.new(name="Armature", type="ARMATURE").object = armature
log("hair bound to %s" % armature.name)

# --- 6. textures --------------------------------------------------------------
# FBX image datablocks carry the authoring machine's absolute paths. Match them
# to our copies by file name; try the stored name, then the datablock name with
# a .png suffix (the hair map's datablock is "EX3_Hair", the file "EX3_hair.png").
available = {}
for root in TEX_DIRS:
    if not os.path.isdir(root):
        continue
    for name in os.listdir(root):
        available.setdefault(name.lower(), os.path.join(root, name))

log("texture pool: %d files across %d roots" % (len(available), len(TEX_DIRS)))
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
        log("  unresolved texture: %s" % image.name)
        continue
    image.filepath = hit
    image.reload()
    log("  %-34s <- %s  %sx%s" % (image.name, os.path.basename(hit), image.size[0], image.size[1]))

# --- 7. shape keys ------------------------------------------------------------
# Drop empty keys by *measurement* rather than by name pattern: the body marks
# its sections with `_____foo_____` and the head with `-foo-`, and one head key is
# a bare `-267`. A key whose every vertex coincides with the basis deforms
# nothing, so it only costs a morph slot in every exported surface.
def basis_positions(mesh):
    keys = mesh.data.shape_keys
    if keys is None or len(keys.key_blocks) == 0:
        return None
    return [tuple(block.co) for block in keys.key_blocks[0].data]


for part in (body, head, *hair_objects):
    keys = part.data.shape_keys
    if keys is None:
        continue
    basis = basis_positions(part)
    dropped = []
    for block in list(keys.key_blocks[1:]):
        worst = 0.0
        for i, vertex in enumerate(block.data):
            dx = vertex.co.x - basis[i][0]
            dy = vertex.co.y - basis[i][1]
            dz = vertex.co.z - basis[i][2]
            distance = dx * dx + dy * dy + dz * dz
            if distance > worst:
                worst = distance
        if worst < 1e-12:
            dropped.append(block.name)
    for name in dropped:
        part.shape_key_remove(keys.key_blocks[name])
    log("%s: dropped %d empty shape keys -> %d remain"
        % (part.name, len(dropped), len(part.data.shape_keys.key_blocks)))
    log("   %s" % dropped)

# --- 8. normalise and ground -------------------------------------------------
def world_bounds(objs):
    low = Vector((1e9, 1e9, 1e9))
    high = Vector((-1e9, -1e9, -1e9))
    for obj in objs:
        for corner in obj.bound_box:
            point = obj.matrix_world @ Vector(corner)
            low = Vector((min(low[i], point[i]) for i in range(3)))
            high = Vector((max(high[i], point[i]) for i in range(3)))
    return low, high


parts = [body, head, *hair_objects]
low, high = world_bounds(parts)
span = high.z - low.z
factor = TARGET_HEIGHT / span
log("body+head height = %.4f m (feet z=%.4f) -> scale x%.4f" % (span, low.z, factor))

# Only the armature is scaled: both meshes are its children, so scaling both
# would scale them twice.
armature.scale = armature.scale * factor
bpy.context.view_layer.update()
bpy.ops.object.select_all(action="DESELECT")
armature.select_set(True)
bpy.context.view_layer.objects.active = armature
bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)

low, high = world_bounds(parts)
shift = Vector((0.0, 0.0, -low.z))
log("grounding: feet at z=%.4f -> shifting by %.4f" % (low.z, shift.z))
armature.location = armature.location + shift
bpy.context.view_layer.update()
bpy.ops.object.select_all(action="DESELECT")
armature.select_set(True)
bpy.context.view_layer.objects.active = armature
bpy.ops.object.transform_apply(location=True, rotation=False, scale=False)

low, high = world_bounds(parts)
log("after: height=%.4f m  feet z=%.4f  top z=%.4f" % (high.z - low.z, low.z, high.z))

# --- 9. VRM 1.0 humanoid mapping ---------------------------------------------
# Names come from the rig's own convention (Unity Humanoid style, _L/_R). The
# *_Twist_* roll bones and the breast bones have no VRM slot. Fingers are skipped:
# nothing animates them individually, and half-mapping VRM 1.0's
# thumbMetacarpal/Proximal/Distal onto this rig's Proximal/Intermediate/Distal
# would silently drop a joint.
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

ext = armature.data.vrm_addon_extension
human_bones = ext.vrm1.humanoid.human_bones
human_bones.initial_automatic_bone_assignment = False
human_bones.filter_by_human_bone_hierarchy = False
lookup = {}
for name, prop in human_bones.human_bone_name_to_human_bone().items():
    lookup[getattr(name, "value", str(name))] = prop

present = {b.name for b in armature.data.bones}
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

# --- 10. expressions ----------------------------------------------------------
# Six of the head's morphs map onto VRM presets one-to-one. Note the spelling:
# the head's keys are `vrc.v.e` / `vrc.v.ih` / `vrc.v.oh` / `vrc.v.ou` (VRChat's
# single-letter visemes) while VRM calls the same sounds ee/ih/oh/ou. Everything
# else stays reachable by shape-key name through the appearance sliders.
EXPRESSION_MAP = {
    "blink": "blink", "aa": "vrc.v.aa", "ih": "vrc.v.ih",
    "ou": "vrc.v.ou", "ee": "vrc.v.e", "oh": "vrc.v.oh",
}
key_names = {k.name for k in head.data.shape_keys.key_blocks}
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
    while len(expression.morph_target_binds) > 0:
        expression.morph_target_binds.remove(expression.morph_target_binds[0])
    bind = expression.morph_target_binds.add()
    # `bind.node` is a read-only pointer to a MeshObjectPropertyGroup; the
    # writable field is the mesh reference inside it. `index` is the *shape key
    # name*, and the exporter silently drops the bind if it is not found.
    bind.node.bpy_object = head
    bind.index = key_name
    bind.weight = 1.0
    bound.append("%s<-%s" % (slot, key_name))
log("expressions bound: %s" % (bound or "none"))
if skipped:
    log("expressions skipped: %s" % skipped)

# --- 11. meta -----------------------------------------------------------------
# This addon version has no `license_url` field and hard-codes one, so the four
# permission fields below are what actually carry the terms.
meta = ext.vrm1.meta
try:
    meta.vrm_name = "Propsmith base figure (Akane head / SiroinoSotai body)"
    meta.version = "1.1"
    meta.authors.clear()
    meta.authors.add().value = "山野重工赤山派閥独立支部 (body: しろいの)"
    meta.copyright_information = "CC0 1.0 Universal (public domain dedication)"
    meta.third_party_licenses = ("Akane head: 山野重工赤山派閥独立支部, CC0. "
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

# --- 12. name the meshes ------------------------------------------------------
# The FBX calls the head's datablock "平面" (plane); that string is what a glTF
# reader sees, and "Body" as the node name for a head is actively misleading.
body.name = "SiroinoSotai_Body"
body.data.name = "SiroinoSotai_Body"
head.name = "Akane_Head"
head.data.name = "Akane_Head"
HAIR_RENAME = {
    "Hair_front": "Akane_Hair_Front",
    "Hair_back": "Akane_Hair_Back",
    "Hair_side": "Akane_Hair_Side",
    "Hair_ahoge": "Akane_Hair_Ahoge",
}
for old, new in HAIR_RENAME.items():
    obj = bpy.data.objects.get(old)
    if obj is not None:
        obj.name = new
        obj.data.name = new
log("renamed meshes: %s" % [o.name for o in parts])

# --- 13. export ---------------------------------------------------------------
bpy.ops.object.select_all(action="DESELECT")
for obj in parts:
    obj.select_set(True)
armature.select_set(True)
bpy.context.view_layer.objects.active = armature

kwargs = {
    "filepath": OUT,
    "armature_object_name": armature.name,
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
