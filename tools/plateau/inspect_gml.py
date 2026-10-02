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


def analyze(dataset_root: str, max_files: int = 0) -> dict:
    """Measure one extracted dataset. Returns a plain dict so callers can tabulate.

    This is the single source of truth for "what can this municipality drive?"; the CLI
    below and `scan_cities.py` both go through it, so a multi-city comparison and a
    single-city report can never disagree about the numbers.
    """
    udx = os.path.join(dataset_root, "udx")
    result: dict = {
        "dataset": dataset_root,
        "ok": os.path.isdir(udx),
        "buildings": 0,
        "coverage": {},
        "usage_values": {},
        "sentinels": {},
        "urf_files": 0,
        "urf_codes": [],
        "tran_files": 0,
        "license_lines": [],
        "readme": "",
    }
    if not result["ok"]:
        return result

    readme = os.path.join(dataset_root, "README.md")
    if os.path.isfile(readme):
        text = _read(readme)
        result["readme"] = text
        for line in text.splitlines():
            if any(k in line for k in ("政府標準利用規約", "クリエイティブ・コモンズ", "ODC BY", "ODbL", "準拠する標準")):
                result["license_lines"].append(line.strip())

    bldg_files = sorted(glob.glob(os.path.join(udx, "bldg", "*.gml")))
    if max_files:
        bldg_files = bldg_files[:max_files]

    present: collections.Counter = collections.Counter()
    usage_values: collections.Counter = collections.Counter()
    sentinels: collections.Counter = collections.Counter()
    buildings = 0

    for path in bldg_files:
        text = _read(path)
        buildings += len(re.findall(r"<[A-Za-z0-9_]+:Building[ >]", text))
        # Prefix-agnostic: a missing attribute must be *proven* missing, not assumed
        # missing because the guessed prefix was wrong.
        usage_values.update(_element_values(text, "usage"))
        for name in INTERESTING:
            local = name.split(":")[1]
            values = _element_values(text, local)
            if values:
                present[name] += sum(values.values())
                for value in values:
                    if value in SENTINELS:
                        sentinels[f"{name}={value}"] += values[value]

    result["buildings"] = buildings
    result["coverage"] = {name: present.get(name, 0) for name in INTERESTING}
    result["usage_values"] = dict(usage_values)
    result["sentinels"] = dict(sentinels)

    urf_files = sorted(glob.glob(os.path.join(udx, "urf", "**", "*.gml"), recursive=True))
    result["urf_files"] = len(urf_files)
    codes: set = set()
    for path in urf_files:
        codes.update(_element_values(_read(path), "function").keys())
    result["urf_codes"] = sorted(codes, key=lambda value: (len(value), value))
    result["tran_files"] = len(glob.glob(os.path.join(udx, "tran", "**", "*.gml"), recursive=True))

    # LOD2 coverage, when the dataset README states it. PLATEAU publishes a LOD1/LOD2
    # breakdown there and nowhere machine-readable.
    match = re.search(r"LOD2[:：]\s*([^\n（(]+)[（(]([^）)]*)[）)]", result["readme"])
    if match:
        result["lod2_summary"] = (match.group(1) + match.group(2)).strip()
    return result


def describe(report: dict) -> None:
    """Human-readable report for one dataset, to stdout."""
    for line in report["license_lines"]:
        print(f"  license/spec: {line}")
    buildings = report["buildings"]
    print(f"\nbuildings:        {buildings}")
    print("\nper-building attribute coverage:")
    for name, count in report["coverage"].items():
        share = (100.0 * count / buildings) if buildings else 0.0
        print(f"  {'OK ' if count else '-- '}{name:<32} {count:>8}  ({share:5.1f}%)")
    if report["sentinels"]:
        print("\nsentinel values treated as 'unknown' (NOT real data):")
        for key, count in sorted(report["sentinels"].items(), key=lambda kv: -kv[1]):
            print(f"  {key}  x{count}")
    print("\nbldg:usage value distribution:")
    if report["usage_values"]:
        for value, count in sorted(report["usage_values"].items(), key=lambda kv: -kv[1]):
            print(f"  {count:>8}  {value!r}")
    else:
        print("  (none — this municipality carries no building use type)")
    print(f"\narea-based fallback: urf files={report['urf_files']} codes={report['urf_codes']}  roads={report['tran_files']}")
    if report.get("lod2_summary"):
        print(f"LOD2 from README: {report['lod2_summary']}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dataset", required=True, help="extracted dataset root (contains udx/)")
    parser.add_argument("--max-files", type=int, default=0, help="limit building files read (0 = all)")
    parser.add_argument("--json", action="store_true", help="emit the report as JSON instead of text")
    args = parser.parse_args()

    report = analyze(args.dataset, args.max_files)
    if not report["ok"]:
        print(f"error: {os.path.join(args.dataset, 'udx')} not found — point --dataset at an extracted CityGML package", file=sys.stderr)
        return 2

    if args.json:
        import json

        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 0

    describe(report)
    usable = report["coverage"].get("bldg:usage", 0) > 0
    print("\nverdict: " + (
        "bldg:usage is populated — tags can come from the buildings themselves."
        if usable else
        "bldg:usage is ABSENT — tags must come from zoning (urf:function) or hand annotation. "
        "This does NOT make the map unusable, only the tag-driven mobility feature."
    ))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
