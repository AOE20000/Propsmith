#!/usr/bin/env python3
"""Inspect an extracted PLATEAU CityGML dataset and report its *tag coverage*.

Why this exists: whether a municipality can drive the tag-based mobility layer is **not**
something PLATEAU guarantees. `bldg:usage`（用途）is the ideal tag source, but it is absent
from some municipalities entirely — 毛呂山町 (2020) has 24,418 buildings and **zero** usage
values, while still carrying height, storey and structure attributes. Assuming otherwise
means building a pipeline against data that does not exist.

Run this against a downloaded dataset *before* committing to a city. It answers:

  * how many buildings there are, and which per-building attributes are actually populated;
  * whether `bldg:usage` exists, and if so its full value distribution;
  * what area-based fallback exists (用途地域 `urf:function` zoning, 土地利用 `luse`);
  * whether the dataset is LOD1-only or has usable LOD2 geometry.

Usage:
    python inspect_gml.py --dataset <extracted dataset root> [--max-files N]

The dataset root is what you get after unzipping one `*_citygml_*_op.zip`: it contains
`udx/`, `codelists/`, `metadata/` and a `README.md`.
"""

from __future__ import annotations

import argparse
import collections
import glob
import os
import re
import sys

# The three attribute spellings we care about most. Note these are matched case-insensitively
# on purpose: the SDK's own documentation writes `bldg:measuredHeight`, while the attribute
# dictionary it hands back uses lowercased keys (`bldg:measuredheight`). A pipeline that
# trusts the document casing silently reads nothing.
INTERESTING = (
    "bldg:usage",
    "bldg:measuredheight",
    "bldg:storeysaboveground",
    "bldg:yearofconstruction",
)

# PLATEAU writes sentinels for "unknown" rather than omitting an element. Treating these as
# data is how a city ends up with buildings 9999 storeys tall.
SENTINELS = {"9999", "-9999", "0001"}


def _read(path: str) -> str:
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def _element_values(text: str, local_name: str) -> collections.Counter:
    """Count the values of `<prefix:local_name>value</prefix:local_name>` regardless of prefix."""
    pattern = re.compile(
        r"<[A-Za-z0-9_]+:%s(?P<attrs>[^>]*)>(?P<value>[^<]*)</[A-Za-z0-9_]+:%s>" % (local_name, local_name),
        re.IGNORECASE,
    )
    return collections.Counter(m.group("value").strip() for m in pattern.finditer(text))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dataset", required=True, help="extracted dataset root (contains udx/)")
    parser.add_argument("--max-files", type=int, default=0, help="limit building files read (0 = all)")
    args = parser.parse_args()

    udx = os.path.join(args.dataset, "udx")
    if not os.path.isdir(udx):
        print(f"error: {udx} not found — point --dataset at an extracted CityGML package", file=sys.stderr)
        return 2

    readme = os.path.join(args.dataset, "README.md")
    if os.path.isfile(readme):
        # The dataset README is the authoritative place the license is stated.
        for line in _read(readme).splitlines():
            if any(k in line for k in ("政府標準利用規約", "クリエイティブ・コモンズ", "ODC BY", "ODbL", "準拠する標準")):
                print(f"  license/spec: {line.strip()}")

    bldg_files = sorted(glob.glob(os.path.join(udx, "bldg", "*.gml")))
    if args.max_files:
        bldg_files = bldg_files[: args.max_files]
    print(f"\nbuilding files: {len(bldg_files)}")

    buildings = 0
    present = collections.Counter()
    usage_values: collections.Counter = collections.Counter()
    sentinel_hits = collections.Counter()

    for path in bldg_files:
        text = _read(path)
        buildings += len(re.findall(r"<[A-Za-z0-9_]+:Building[ >]", text))
        # Any element whose local name ends in "usage", prefix-agnostic: a missing attribute
        # must be proven missing, not assumed missing because of a guessed prefix.
        usage_values.update(_element_values(text, "usage"))
        for name in INTERESTING:
            local = name.split(":")[1]
            values = _element_values(text, local)
            if values:
                present[name] += sum(values.values())
                for value in values:
                    if value in SENTINELS:
                        sentinel_hits[f"{name}={value}"] += values[value]

    print(f"buildings:        {buildings}")
    print("\nper-building attribute coverage:")
    for name in INTERESTING:
        count = present.get(name, 0)
        share = (100.0 * count / buildings) if buildings else 0.0
        mark = "OK " if count else "-- "
        print(f"  {mark}{name:<32} {count:>8}  ({share:5.1f}%)")
    if sentinel_hits:
        print("\nsentinel values treated as 'unknown' (NOT real data):")
        for key, count in sentinel_hits.most_common():
            print(f"  {key}  x{count}")

    print("\nbldg:usage value distribution:")
    if usage_values:
        for value, count in usage_values.most_common():
            print(f"  {count:>8}  {value!r}")
    else:
        print("  (none — this municipality carries no building use type)")

    # Area-based fallbacks, for the case where per-building usage is missing.
    print("\narea-based fallback sources:")
    for feature, label in (("urf", "zoning 用途地域 urf:function"), ("luse", "land use luse:usage"), ("tran", "roads tran")):
        files = sorted(glob.glob(os.path.join(udx, feature, "**", "*.gml"), recursive=True))
        detail = ""
        if files and feature == "urf":
            counts: collections.Counter = collections.Counter()
            for path in files:
                counts.update(_element_values(_read(path), "function"))
            detail = f"  distinct function codes: {sorted(counts)}"
        print(f"  {label:<34} files={len(files)}{detail}")

    lod2 = sum(1 for v in (present.get("bldg:measuredheight", 0),) if v) and "unknown from attributes"
    print(f"\nLOD: {lod2} — read the dataset README for the LOD1/LOD2 breakdown; LOD2 is often")
    print("     present only for a handful of landmarks, so 'textured LOD2 city' is not a given.")

    usable = present.get("bldg:usage", 0) > 0
    print("\nverdict: " + (
        "bldg:usage is populated — the tag-driven mobility layer can use this municipality directly."
        if usable else
        "bldg:usage is ABSENT — drive tags from zoning (urf:function) or hand annotation, "
        "or pick a municipality that populates usage."
    ))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
