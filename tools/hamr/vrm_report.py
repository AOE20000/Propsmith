#!/usr/bin/env python3
"""Authoritative report on a VRM file — the checks that actually decide whether
a model is usable, read out of the file instead of inferred from a tool.

Why this exists: `hamr verify-rig` reads the *Blender scene* and matches bone
names against the VRM standard list, so it reports "14/25 bones found, invalid"
for a model whose `VRMC_vrm.humanoid.humanBones` table maps all 25 slots
correctly (MB-Lab names its bones `pelvis` / `upperarm_L`, and the mapping table
is what the spec actually requires). Meanwhile it says nothing about the failures
that do hurt: a garment mesh whose vertices carry no weights, a mesh that
quietly carries 82 expression morphs it has no business carrying, or geometry
that reaches the exporter with stray vertices flung across the body.

Usage:
    python tools/hamr/vrm_report.py <model.vrm>
    python tools/hamr/vrm_report.py <model.vrm> --quiet   # exit code only

Exit code is 0 when every check passes, 1 otherwise, so it can gate a batch run
(the NPC generator will produce dozens of these).
"""

from __future__ import annotations

import argparse
import json
import struct
import sys

HUMANOID_SLOTS = (
    "hips", "spine", "chest", "upperChest", "neck", "head",
    "leftShoulder", "leftUpperArm", "leftLowerArm", "leftHand",
    "rightShoulder", "rightUpperArm", "rightLowerArm", "rightHand",
    "leftUpperLeg", "leftLowerLeg", "leftFoot", "leftToes",
    "rightUpperLeg", "rightLowerLeg", "rightFoot", "rightToes",
    "leftEye", "rightEye", "jaw",
)

# VRM 1.0 requires only these; everything else on the list above is optional
# (upperChest, shoulders, toes, eyes, jaw). A rig without a face simply has no
# eye/jaw bones and is still perfectly valid — reporting that as "missing" would
# train the reader to ignore the line that matters.
REQUIRED_SLOTS = (
    "hips", "spine", "head",
    "leftUpperArm", "leftLowerArm", "leftHand",
    "rightUpperArm", "rightLowerArm", "rightHand",
    "leftUpperLeg", "leftLowerLeg", "leftFoot",
    "rightUpperLeg", "rightLowerLeg", "rightFoot",
)

_COMPONENT_SIZE = {5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4}
_TYPE_COUNT = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}


def load_glb(path: str):
    with open(path, "rb") as handle:
        magic, version, length = struct.unpack("<4sII", handle.read(12))
        if magic != b"glTF":
            raise ValueError("not a GLB container: %r" % magic)
        gltf = None
        binary = b""
        while handle.tell() < length:
            header = handle.read(8)
            if len(header) < 8:
                break
            chunk_length, chunk_type = struct.unpack("<I4s", header)
            data = handle.read(chunk_length)
            if chunk_type == b"JSON":
                gltf = json.loads(data)
            elif chunk_type.rstrip(b"\x00") == b"BIN":
                binary = data
    if gltf is None:
        raise ValueError("no JSON chunk")
    return gltf, binary, length


def read_accessor(gltf, binary, index):
    accessor = gltf["accessors"][index]
    view = gltf["bufferViews"][accessor["bufferView"]]
    count = accessor["count"]
    components = _TYPE_COUNT[accessor["type"]]
    size = _COMPONENT_SIZE[accessor["componentType"]]
    stride = view.get("byteStride") or components * size
    start = view.get("byteOffset", 0) + accessor.get("byteOffset", 0)
    fmt = {5126: "f", 5123: "H", 5121: "B", 5125: "I", 5122: "h", 5120: "b"}[
        accessor["componentType"]
    ]
    out = []
    for i in range(count):
        offset = start + i * stride
        out.append(struct.unpack_from("<" + fmt * components, binary, offset))
    return out


def report(path: str, quiet: bool = False) -> int:
    gltf, binary, length = load_glb(path)
    problems = []
    lines = []

    def say(text: str = "") -> None:
        lines.append(text)

    say("=" * 68)
    say("VRM REPORT  %s" % path)
    say("=" * 68)
    say("container: %.1f MB" % (length / 1048576))

    # ---- rig: the humanoid mapping table is the spec's contract -------------
    vrm = gltf.get("extensions", {}).get("VRMC_vrm", {})
    humanoid = vrm.get("humanoid", {}).get("humanBones", {})
    nodes = gltf.get("nodes", [])
    absent = [slot for slot in HUMANOID_SLOTS if slot not in humanoid]
    absent_required = [slot for slot in REQUIRED_SLOTS if slot not in humanoid]
    optional_absent = [slot for slot in absent if slot not in REQUIRED_SLOTS]
    say("")
    say("humanoid: %d/%d slots mapped (%d required, %d optional)"
        % (len(HUMANOID_SLOTS) - len(absent), len(HUMANOID_SLOTS),
           len(REQUIRED_SLOTS) - len(absent_required), len(HUMANOID_SLOTS) - len(REQUIRED_SLOTS)))
    if absent_required:
        problems.append("required humanoid slots missing: %s" % ", ".join(absent_required))
        say("  REQUIRED MISSING: %s" % ", ".join(absent_required))
    if optional_absent:
        say("  optional absent (fine): %s" % ", ".join(optional_absent))
    for slot in ("hips", "head", "leftUpperArm", "rightUpperArm", "leftUpperLeg"):
        if slot in humanoid:
            node = nodes[humanoid[slot].get("node", -1)]
            say("  %-14s -> %s" % (slot, node.get("name", "?")))

    skins = gltf.get("skins", [])
    say("skins: %d, joints: %s" % (len(skins), [len(s.get("joints", [])) for s in skins]))

    # ---- meshes: weights present, and no expressions on garments -----------
    say("")
    say("meshes:")
    # The morph-carrying mesh is the body; identify it by vertex count rather
    # than by name, because third-party rigs name it whatever they like
    # (MBLab_*, SiroinoSotai_PC, ...) and a name list can only ever be a guess.
    sizes: dict[str, int] = {}
    for mesh in gltf.get("meshes", []):
        attributes = [p.get("attributes", {}) for p in mesh["primitives"]]
        sizes[mesh.get("name", "?")] = sum(
            gltf["accessors"][a["POSITION"]]["count"] for a in attributes if "POSITION" in a
        )
    body_mesh = max(sizes, key=sizes.get) if sizes else ""
    shape: dict[str, tuple] = {}
    morph_counts: dict[str, int] = {}
    for mesh in gltf.get("meshes", []):
        name = mesh.get("name", "?")
        verts = 0
        tris = 0
        morphs = 0
        unweighted = 0
        bounds = None
        for primitive in mesh["primitives"]:
            attributes = primitive.get("attributes", {})
            position = attributes.get("POSITION")
            if position is not None:
                accessor = gltf["accessors"][position]
                verts += accessor["count"]
                if "min" in accessor and "max" in accessor:
                    if bounds is None:
                        bounds = [list(accessor["min"]), list(accessor["max"])]
                    else:
                        bounds[0] = [min(a, b) for a, b in zip(bounds[0], accessor["min"])]
                        bounds[1] = [max(a, b) for a, b in zip(bounds[1], accessor["max"])]
            if "indices" in primitive:
                tris += gltf["accessors"][primitive["indices"]]["count"] // 3
            morphs = max(morphs, len(primitive.get("targets", [])))

            weights = attributes.get("WEIGHTS_0")
            if weights is None and position is not None:
                unweighted += gltf["accessors"][position]["count"]
            elif weights is not None:
                for row in read_accessor(gltf, binary, weights):
                    if sum(row) <= 0.0:
                        unweighted += 1
        if bounds is None:
            bounds = [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]
        size = [round(b - a, 3) for a, b in zip(bounds[0], bounds[1])]
        say("  %-34s verts=%-6d tris=%-6d morphs=%-3d aabb=%s"
            % (name[:34], verts, tris, morphs, size))
        if unweighted:
            problems.append("%s: %d vertices carry no skin weight" % (name, unweighted))
            say("      !! %d vertices without weights (VRM 1.0 forbids this)" % unweighted)
        # Morph targets are only suspicious on a non-body mesh as *duplicated*
        # body morphs — the signature of a copy step that forgot to restrict
        # itself (the Hamr clothing bug: four meshes each carrying the body's 82
        # targets). A separate mesh with its own morphs is perfectly normal: a
        # head carries the expressions, the body carries the body shapes.
        morph_counts[name] = morphs
        shape[name] = (verts, tuple(size))

    body_morphs = morph_counts.get(body_mesh, 0)
    for name, morphs in morph_counts.items():
        if name == body_mesh or morphs == 0:
            continue
        if body_morphs and morphs == body_morphs:
            problems.append(
                "%s: carries the body's %d morph targets unchanged — "
                "a duplicated morph set, not its own" % (name, morphs)
            )
            say("      !! %s duplicates the body's %d morph targets" % (name, morphs))

    # A "garment" that is the body over again is the signature of a duplicate
    # stage that never restricted itself to a region — the mesh count and the
    # bounds match the body to the vertex. Cheap to test, and it is the only
    # thing that separates "dressed" from "naked body with clothing materials".
    seen: dict[tuple, str] = {}
    for name, signature in shape.items():
        verts, size = signature
        if verts < 500:
            continue
        previous = seen.get(signature)
        if previous is not None:
            problems.append(
                "%s and %s are the same surface (%d verts, aabb %s): "
                "a garment that duplicates the body instead of covering a region"
                % (previous, name, verts, list(size))
            )
            say("      !! identical to %s — duplicate surface, not a garment" % previous)
        else:
            seen[signature] = name

    # ---- textures and materials -------------------------------------------
    views = gltf.get("bufferViews", [])
    images = gltf.get("images", [])
    texture_bytes = sum(
        views[image["bufferView"]]["byteLength"] for image in images if "bufferView" in image
    )
    say("")
    say("textures: %d, %.1f MB embedded" % (len(images), texture_bytes / 1048576))
    for index, image in enumerate(images):
        size = views[image["bufferView"]]["byteLength"] if "bufferView" in image else 0
        say("  [%d] %-28s %.2f MB" % (index, image.get("name", "-")[:28], size / 1048576))
    if images and texture_bytes > 20 * 1048576:
        say("  note: over 20 MB of textures; downscale before shipping a crowd")

    materials = gltf.get("materials", [])
    untextured = [m for m in materials
                  if not m.get("pbrMetallicRoughness", {}).get("baseColorTexture")]
    near_white = []
    for material in untextured:
        factor = material.get("pbrMetallicRoughness", {}).get("baseColorFactor") or [1, 1, 1, 1]
        if min(factor[:3]) > 0.9:
            near_white.append(material.get("name", "?"))
    say("materials: %d (%d with no base-colour texture, %d of those near-white)"
        % (len(materials), len(untextured), len(near_white)))
    # A flat colour is a legitimate authoring choice; only a flat *white* with no
    # texture at all means the albedo went missing. Telling the two apart is the
    # difference between a useful gate and a line the reader learns to ignore.
    if materials and len(untextured) == len(materials):
        if near_white:
            problems.append("near-white materials with no base-colour texture: albedo lost or never authored")
            say("  !! %s is ~white and untextured — albedo lost or never authored"
                % ", ".join(near_white))
        else:
            say("  note: flat colours by design (untextured, but the factors are not white)")
    if images and not any(m.get("pbrMetallicRoughness", {}).get("baseColorTexture")
                          for m in materials):
        say("  note: %d image(s) present but none used as base colour (normal map only?)"
            % len(images))

    say("")
    if problems:
        say("RESULT: FAIL (%d)" % len(problems))
        for problem in problems:
            say("  - %s" % problem)
    else:
        say("RESULT: OK")

    if not quiet:
        print("\n".join(lines))
    return 1 if problems else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model", help="path to a .vrm / .vrm1 file")
    parser.add_argument("--quiet", action="store_true", help="exit code only")
    args = parser.parse_args()
    return report(args.model, quiet=args.quiet)


if __name__ == "__main__":
    sys.exit(main())
