#!/usr/bin/env python3
"""Scan several PLATEAU municipalities and compare what each one can actually drive.

Why this exists: `bldg:usage`（用途）is not a guaranteed PLATEAU attribute — one measured
municipality had 24,418 buildings and zero usage values. Picking the default city therefore
has to be a *measured* decision, and one sample is not enough. This walks a list of areas,
pulls each one's newest CityGML package, measures it with the same analysis the
single-dataset inspector uses, and prints one comparison row per area.

The report is deliberately a *capability* report, not a pass/fail grade. Tag-driven mobility
is an optional feature: a municipality with no usable tags is still a perfectly good map,
it just cannot turn that feature on. So each row answers:

    usage%   can tags come from the buildings themselves? (best case)
    zoning   is there an area-based fallback (用途地域 urf:function)?
    LOD2     is there anything better than a LOD1 block model to look at?

Usage:
    python scan_cities.py --areas 渋谷区,新宿区,横浜市,名古屋市,福岡市,札幌市
    python scan_cities.py --areas 渋谷区 --proxy http://127.0.0.1:7890 --keep

Notes from doing this by hand first:
  * CKAN's `resources[].size` is always 0 — do not try to use it to choose.
  * The datasets live on `assets.cms.plateau.reearth.io`, which may need the local proxy.
  * Only the members the analysis needs are extracted (bldg + urf + codelists + README), so a
    1 GB package does not have to be unpacked in full.
"""

from __future__ import annotations

import argparse
import base64
import io
import json
import os
import re
import shutil
import ssl
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import inspect_gml  # noqa: E402 - deliberately imported after sys.path setup

CKAN_SEARCH = "https://www.geospatial.jp/ckan/api/3/action/package_search"
NEEDED_MEMBERS = ("udx/bldg/", "udx/urf/", "udx/tran/", "codelists/", "README.md")

## geospatial.jp drops the TLS handshake intermittently — first measured run died on the very
## first request with `SSL: UNEXPECTED_EOF_WHILE_READING`, while both curl and a repeat of the
## same urllib call succeeded seconds later. So this is a flaky server, not a transport problem,
## and the answer is to retry rather than to swap HTTP libraries.
TRANSIENT_ERRORS = (
    urllib.error.URLError,
    ssl.SSLError,
    TimeoutError,
    ConnectionResetError,
    ConnectionAbortedError,
)


def with_retries(operation, what: str, attempts: int = 4, delay: float = 1.5):
    """Run `operation`, retrying only on errors that are plausibly temporary."""
    last_error: Exception | None = None
    for attempt in range(1, attempts + 1):
        try:
            return operation()
        except urllib.error.HTTPError as error:
            # A 4xx is our mistake, not the network's — retrying cannot help.
            if 400 <= error.code < 500:
                raise
            last_error = error
        except TRANSIENT_ERRORS as error:
            last_error = error
        print(f"    retry {attempt}/{attempts} ({what}): {last_error}", file=sys.stderr, flush=True)
        time.sleep(delay * attempt)
    assert last_error is not None
    raise last_error


def _opener(proxy: str | None) -> urllib.request.OpenerDirector:
    handlers = []
    if proxy:
        handlers.append(urllib.request.ProxyHandler({"http": proxy, "https": proxy}))
    return urllib.request.build_opener(*handlers)


def _get_json(opener, url: str, timeout: int = 60) -> dict:
    def fetch() -> dict:
        with opener.open(url, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8"))

    return with_retries(fetch, "ckan")


def find_package(opener, area: str) -> dict | None:
    """The PLATEAU 3D city model dataset for an area.

    CKAN's search returns everything that merely *mentions* the name — land-registry map
    data, barrier-free datasets, a ward's cadastral parcels. Taking the first match is how the
    first version of this script reported `no-citygml` for Shibuya. So the filter is what
    actually matters: the package must *contain a CityGML resource*, and among those the
    newest fiscal year wins.
    """
    url = f"{CKAN_SEARCH}?q={urllib.parse.quote(area)}&rows=20"
    results = _get_json(opener, url)["result"]["results"]

    best: tuple[int, dict] | None = None
    for package in results:
        name = str(package.get("title", ""))
        if area not in str(package.get("area", "")) and area not in name:
            continue
        if find_citygml_resource(package) is None:
            continue
        # Title carries the fiscal year, e.g. "…渋谷区（2025年度）".
        match = re.search(r"(\d{4})\s*年度", name)
        year = int(match.group(1)) if match else 0
        if best is None or year > best[0]:
            best = (year, package)
    return best[1] if best else None


def catalogue_size_mb(opener, package: dict) -> int | None:
    """Size of the CityGML package, read from the dataset's own データ目録.

    PLATEAU embeds the file manifest as **base64-encoded markdown inside the resource URL**
    (`data:text/markdown;base64,…`), and that manifest states each file's size. That is the only
    way to know how big a package is before downloading it: CKAN's `resources[].size` is always
    0, and the asset host does not answer HEAD. Without this, an oversized package is
    discovered by downloading most of it and aborting.
    """
    for resource in package.get("resources", []):
        url = str(resource.get("url", ""))
        if not url.startswith("data:text/markdown;base64,"):
            continue
        try:
            markdown = base64.b64decode(url.split(",", 1)[1]).decode("utf-8")
        except (ValueError, UnicodeDecodeError):
            continue
        for line in markdown.splitlines():
            if "_citygml_" not in line:
                continue
            # Datasets are inconsistent about parentheses and spacing — some write `(649 MB)`,
            # others full-width `（649 MB）` — so accept both rather than silently reporting
            # "unknown size" for half the country.
            match = re.search(r"[（(]\s*([\d,]+)\s*MB\s*[）)]", line)
            if match:
                return int(match.group(1).replace(",", ""))
    return None


def find_citygml_resource(package: dict) -> dict | None:
    """Newest CityGML package in a dataset.

    Version is read from the filename (`..._citygml_<n>_op.zip`), because PLATEAU's resource
    *names* are only `CityGML`, `CityGML（v2）` … and the number in the filename is the one that
    actually increases with each release.
    """
    best: tuple[int, dict] | None = None
    for resource in package.get("resources", []):
        if not str(resource.get("name", "")).startswith("CityGML"):
            continue
        url = str(resource.get("url", ""))
        match = re.search(r"_citygml_(\d+)_", url)
        version = int(match.group(1)) if match else 0
        if best is None or version > best[0]:
            best = (version, resource)
    return best[1] if best else None


def download(opener, url: str, target: str, max_bytes: int) -> tuple[bool, int]:
    """Stream a URL to disk, refusing to exceed `max_bytes`. Returns (ok, size).

    Retried as a whole: a dropped connection restarts the transfer from zero rather than
    resuming, which is fine for these packages and much simpler than range requests.
    """
    def attempt() -> tuple[bool, int]:
        written = 0
        with opener.open(url, timeout=180) as response, open(target, "wb") as handle:
            while True:
                chunk = response.read(1 << 20)
                if not chunk:
                    break
                written += len(chunk)
                if max_bytes and written > max_bytes:
                    handle.close()
                    os.remove(target)
                    return False, written
                handle.write(chunk)
        return True, written

    return with_retries(attempt, "download")


def extract_needed(zip_path: str, dest: str) -> None:
    """Extract only the members the analysis reads, so a large package stays cheap."""
    with zipfile.ZipFile(zip_path) as archive:
        for member in archive.namelist():
            if any(member.startswith(prefix) or member == prefix for prefix in NEEDED_MEMBERS):
                if member.endswith("/"):
                    continue
                # Skip the giant terrain/land-use/risk members we do not measure.
                if any(member.startswith(skip) for skip in ("udx/dem/", "udx/luse/", "udx/fld/", "udx/lsld/")):
                    continue
                archive.extract(member, dest)


def scan_one(opener, area: str, work_dir: str, max_bytes: int, keep: bool) -> dict:
    """Measure one area. Never raises: a failure is recorded as that row's status.

    Everything, including the CKAN lookup, is inside the try — one flaky request must cost
    one row, not the whole scan.
    """
    row: dict = {"area": area, "status": "not-found"}
    zip_path = os.path.join(work_dir, f"{area}.zip")
    data_dir = os.path.join(work_dir, area)
    try:
        package = find_package(opener, area)
        if package is None:
            return row
        row["dataset_title"] = str(package.get("title", ""))[:60]

        resource = find_citygml_resource(package)
        if resource is None:
            row["status"] = "no-citygml"
            return row
        row["url"] = str(resource["url"])

        # Read the size off the dataset's own manifest and decline before downloading.
        declared_mb = catalogue_size_mb(opener, package)
        row["declared_mb"] = declared_mb
        if declared_mb is not None and max_bytes and declared_mb * (1 << 20) > max_bytes:
            row["status"] = f"too-big({declared_mb}MB declared)"
            return row

        ok, size = download(opener, row["url"], zip_path, max_bytes)
        if not ok:
            row["status"] = f"too-big(>{max_bytes // (1 << 20)}MB)"
            return row
        row["package_mb"] = round(size / (1 << 20), 1)
        os.makedirs(data_dir, exist_ok=True)
        extract_needed(zip_path, data_dir)

        report = inspect_gml.analyze(data_dir)
        row.update({
            "status": "ok",
            "buildings": report["buildings"],
            "usage": report["coverage"].get("bldg:usage", 0),
            "measured_height": report["coverage"].get("bldg:measuredheight", 0),
            "storeys": report["coverage"].get("bldg:storeysaboveground", 0),
            "sentinels": report["sentinels"],
            "usage_values": report["usage_values"],
            "urf_codes": report["urf_codes"],
            "tran_files": report["tran_files"],
            "lod2": report.get("lod2_summary", ""),
            "license": report["license_lines"],
        })
    except Exception as error:  # noqa: BLE001 - one bad row must not end the scan
        row["status"] = f"error: {type(error).__name__}: {error}"
    finally:
        if not keep:
            if os.path.isfile(zip_path):
                os.remove(zip_path)
            shutil.rmtree(data_dir, ignore_errors=True)
    return row


def print_table(rows: list[dict]) -> None:
    header = f"{'area':<10} {'status':<12} {'bldgs':>7} {'usage%':>7} {'height%':>8} {'storeys%':>9} {'sent%':>6} {'urf':>4} {'roads':>5}  LOD2"
    print(header)
    print("-" * len(header))
    for row in rows:
        if row["status"] != "ok":
            print(f"{row['area']:<10} {row['status']:<12}")
            continue
        buildings = max(row["buildings"], 1)
        sentinel_total = sum(row["sentinels"].values())
        print(
            f"{row['area']:<10} {'ok':<12} {row['buildings']:>7} "
            f"{100.0 * row['usage'] / buildings:>6.1f}% "
            f"{100.0 * row['measured_height'] / buildings:>7.1f}% "
            f"{100.0 * row['storeys'] / buildings:>8.1f}% "
            f"{100.0 * sentinel_total / buildings:>5.1f}% "
            f"{len(row['urf_codes']):>4} {row['tran_files']:>5}  {row['lod2'][:28]}"
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--areas", required=True, help="comma-separated area names, e.g. 渋谷区,横浜市")
    parser.add_argument("--proxy", default=os.environ.get("PLATEAU_PROXY", ""), help="e.g. http://127.0.0.1:7890")
    parser.add_argument("--work-dir", default=os.path.join(tempfile.gettempdir(), "plateau-scan"),
                        help="where downloads and extracted datasets go (default: the OS temp dir — "
                             "scan output must never end up inside the repository)")
    parser.add_argument("--max-mb", type=int, default=400, help="skip a package larger than this (0 = no limit)")
    parser.add_argument("--keep", action="store_true", help="keep downloaded and extracted data")
    args = parser.parse_args()

    opener = _opener(args.proxy or None)
    os.makedirs(args.work_dir, exist_ok=True)
    max_bytes = args.max_mb * (1 << 20)

    rows: list[dict] = []
    for area in [piece.strip() for piece in args.areas.split(",") if piece.strip()]:
        print(f"[scan] {area} …", file=sys.stderr, flush=True)
        row = scan_one(opener, area, args.work_dir, max_bytes, args.keep)
        print(f"[scan] {area}: {row['status']}", file=sys.stderr, flush=True)
        rows.append(row)

    print()
    print_table(rows)

    for row in rows:
        if row["status"] == "ok" and row["usage_values"]:
            print(f"\n{row['area']} bldg:usage values: {row['usage_values']}")
    summary = os.path.join(args.work_dir, "scan.json")
    with open(summary, "w", encoding="utf-8") as handle:
        json.dump(rows, handle, ensure_ascii=False, indent=2)
    print(f"\nfull report: {summary}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
