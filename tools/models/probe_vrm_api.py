"""List the VRM 1.0 addon's meta / expressions property names.

`--python-expr` swallowed this output; a real file does not.

  <blender> --background --python tools/models/probe_vrm_api.py
"""
import addon_utils
import bpy

addon_utils.enable("io_scene_vrm", default_set=True, persistent=True)


def say(*args):
    print("[vrmapi]", *args)


ext = bpy.types.Armature.vrm_addon_extension
# `bpy.types.Armature.vrm_addon_extension` is a class-level descriptor
# (_PropertyDeferred), so it only resolves on a real instance — make one.
bpy.ops.object.armature_add()
arm = bpy.context.active_object
say("armature object: %s" % arm.name)
ext = arm.data.vrm_addon_extension
meta = ext.vrm1.meta
say("meta properties:")
for prop in meta.bl_rna.properties:
    if prop.identifier in ("rna_type",):
        continue
    try:
        value = getattr(meta, prop.identifier)
    except Exception as exc:  # noqa: BLE001
        value = "<%s>" % exc
    if prop.type == "ENUM":
        items = [i.identifier for i in prop.enum_items]
        say("  %-34s ENUM  %s" % (prop.identifier, items))
    elif prop.type == "COLLECTION":
        say("  %-34s COLLECTION" % prop.identifier)
    else:
        say("  %-34s %-10s %r" % (prop.identifier, prop.type, value))

expressions = ext.vrm1.expressions
say("")
say("expressions properties:")
for prop in expressions.bl_rna.properties:
    if prop.identifier == "rna_type":
        continue
    say("  %-34s %s" % (prop.identifier, prop.type))

preset = getattr(expressions, "preset", None)
if preset is not None:
    say("")
    say("preset slots:")
    names = [p.identifier for p in preset.bl_rna.properties if p.identifier != "rna_type"]
    say("  %s" % names)
    first = getattr(preset, names[0], None)
    if first is not None:
        say("")
        say("one preset (%s) properties:" % names[0])
        for prop in first.bl_rna.properties:
            if prop.identifier == "rna_type":
                continue
            say("    %-30s %s" % (prop.identifier, prop.type))
        binds = getattr(first, "morph_target_binds", None)
        if binds is not None:
            say("    morph_target_binds: %d" % len(binds))
            bind = binds.add()
            say("    bind properties: %s"
                % [p.identifier for p in bind.bl_rna.properties
                   if p.identifier != "rna_type"])
