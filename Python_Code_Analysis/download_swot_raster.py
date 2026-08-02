#!/usr/bin/env python3
"""Download SWOT L2 HR Raster (Version D) granules for New York State.

Wraps the PO.DAAC ``podaac-data-downloader`` CLI
(https://github.com/podaac/data-subscriber/blob/main/Downloader.md), adding the
pieces that CLI does not do on its own:

  * a ``--report`` mode that asks CMR how many granules / how many GB a given
    request would pull, *before* committing to the download;
  * an ``--extent ghg`` mode that turns the field sites in
    ``Data/FieldData/GHG/`` into a small set of buffered bounding boxes, so the
    download follows the points instead of the whole state bbox;
  * time-chunking + a process pool, because the downloader itself is serial and
    the full-state request is a few hundred GB.

Collection: SWOT_L2_HR_Raster_D (C3233944993-POCLOUD), "SWOT Level 2 Water Mask
Raster Image Data Product, Version D".

Note on the record: the collection's advertised start is 2022-12-16 (launch),
but the earliest HR raster granules over New York are 2023-03-29. A request
starting in 2022 is legal, it just returns nothing before that date.

Granules come in two grid samplings, both on UTM:
  100m  ~63 MB each
  250m  ~16 MB each

Authentication is NASA Earthdata Login, read from ``~/.netrc``. See --help.

Examples
--------
    # How big is this actually?
    python download_swot_raster.py --report --extent ny
    python download_swot_raster.py --report --extent ghg

    # Whole state, 100 m, 2022-2025, 6 concurrent downloader processes
    python download_swot_raster.py --extent ny --resolution 100m --jobs 6

    # Just the GHG field sites, both samplings
    python download_swot_raster.py --extent ghg --resolution both --jobs 6
"""

from __future__ import annotations

import argparse
import collections
import glob
import json
import math
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------

SHORT_NAME = "SWOT_L2_HR_Raster_D"
CMR_GRANULES = "https://cmr.earthdata.nasa.gov/search/granules.umm_json"

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = PROJECT_ROOT / "Data" / "SWOT"
GHG_DIR = PROJECT_ROOT / "Data" / "FieldData" / "GHG"

# New York State, padded enough to catch tiles that only clip the border.
NY_BBOX = (-79.95, 40.40, -71.75, 45.10)

DEFAULT_START = "2022-01-01T00:00:00Z"
DEFAULT_END = "2026-01-01T00:00:00Z"

# Grid sampling filters. Two different mechanisms, deliberately:
#
#   cmr  - a CMR readable_granule_name wildcard, used by --report only.
#   ext  - a regex for the downloader's -e/--extensions flag. NOT -gr: the
#          downloader treats -gr as an *alternative* to the temporal search
#          (podaac_data_downloader.py, the `elif granule is not None` branch),
#          so passing it silently discards -sd/-ed and matches the whole
#          mission record. -e filters the resolved download URLs instead, and
#          is applied as re.search(pattern + "$", url).
RESOLUTIONS = {
    "100m": {"cmr": "SWOT_L2_HR_Raster_100m*", "ext": r"_Raster_100m_.*\.nc"},
    "250m": {"cmr": "SWOT_L2_HR_Raster_250m*", "ext": r"_Raster_250m_.*\.nc"},
    "both": {"cmr": None, "ext": r"\.nc"},
}

EARTHDATA_HOST = "urs.earthdata.nasa.gov"


# --------------------------------------------------------------------------
# CMR
# --------------------------------------------------------------------------


def cmr_search(bbox, start, end, name_pattern=None, timeout=120):
    """Page through CMR and yield (granule_name, size_mb) for one bbox/window."""
    params = {
        "short_name": SHORT_NAME,
        "bounding_box": ",".join(f"{v}" for v in bbox),
        "temporal": f"{start},{end}",
        "page_size": 1000,
    }
    if name_pattern:
        params["readable_granule_name"] = name_pattern
        params["options[readable_granule_name][pattern]"] = "true"

    search_after = None
    while True:
        req = urllib.request.Request(CMR_GRANULES + "?" + urllib.parse.urlencode(params))
        if search_after:
            req.add_header("CMR-Search-After", search_after)
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            search_after = resp.headers.get("CMR-Search-After")
            payload = json.load(resp)

        items = payload.get("items", [])
        for item in items:
            umm = item["umm"]
            size = sum(
                info.get("Size", 0.0)
                for info in umm.get("DataGranule", {}).get(
                    "ArchiveAndDistributionInformation", []
                )
                if info.get("SizeUnit") == "MB"
            )
            yield umm["GranuleUR"], size

        if not items or not search_after:
            break


def report(bboxes, start, end, resolution):
    """Print granule counts and volume per year and per grid sampling."""
    pattern = RESOLUTIONS[resolution]["cmr"]
    granules = {}

    print(f"Querying CMR for {SHORT_NAME} over {len(bboxes)} box(es)...", file=sys.stderr)
    for i, bbox in enumerate(bboxes, 1):
        for name, size in cmr_search(bbox, start, end, pattern):
            granules[name] = size
        if i % 10 == 0 or i == len(bboxes):
            print(f"  box {i}/{len(bboxes)}: {len(granules)} unique granules",
                  file=sys.stderr)

    if not granules:
        print("\nNo granules matched.")
        return granules

    by_year = collections.defaultdict(lambda: collections.defaultdict(lambda: [0, 0.0]))
    for name, size in granules.items():
        res = re.search(r"_Raster_(\d+m)_", name)
        res = res.group(1) if res else "?"
        stamp = re.search(r"_(\d{8})T\d{6}_", name)
        year = stamp.group(1)[:4] if stamp else "????"
        cell = by_year[year][res]
        cell[0] += 1
        cell[1] += size

    print(f"\n{SHORT_NAME}  {start} -> {end}")
    print(f"{'year':<8}{'grid':<8}{'granules':>10}{'size':>12}")
    print("-" * 38)
    total_n = total_mb = 0
    for year in sorted(by_year):
        for res in sorted(by_year[year]):
            n, mb = by_year[year][res]
            print(f"{year:<8}{res:<8}{n:>10}{mb / 1024:>10.1f} GB")
            total_n += n
            total_mb += mb
    print("-" * 38)
    print(f"{'TOTAL':<16}{total_n:>10}{total_mb / 1024:>10.1f} GB")
    return granules


# --------------------------------------------------------------------------
# Extents
# --------------------------------------------------------------------------


def read_ghg_points(pattern="*.gpkg"):
    """Read WGS84 lon/lat from the GHG GeoPackages.

    The Latitude/Longitude attribute columns are plain WGS84 degrees (they match
    the reprojected geometry exactly), so this reads them straight out of the
    GeoPackage's SQLite tables and needs no GDAL/geopandas.
    """
    points = set()
    files = sorted(glob.glob(str(GHG_DIR / pattern)))
    if not files:
        raise SystemExit(f"No GeoPackages found under {GHG_DIR}")

    for path in files:
        con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        try:
            tables = [r[0] for r in con.execute("SELECT table_name FROM gpkg_contents")]
            for table in tables:
                cols = {r[1].lower(): r[1] for r in con.execute(f'PRAGMA table_info("{table}")')}
                if "latitude" not in cols or "longitude" not in cols:
                    continue
                rows = con.execute(
                    f'SELECT "{cols["longitude"]}", "{cols["latitude"]}" FROM "{table}" '
                    f'WHERE "{cols["longitude"]}" IS NOT NULL AND "{cols["latitude"]}" IS NOT NULL'
                )
                for lon, lat in rows:
                    points.add((round(float(lon), 5), round(float(lat), 5)))
        finally:
            con.close()

    if not points:
        raise SystemExit(f"Found GeoPackages in {GHG_DIR} but no Latitude/Longitude columns")
    return sorted(points)


def ghg_bboxes(buffer_km=10.0, max_span_deg=1.5):
    """Buffer the GHG sites and greedily merge them into a few bounding boxes.

    Merging keeps the number of downloader invocations small; ``max_span_deg``
    stops the merge from collapsing back into the full-state bbox.
    """
    points = read_ghg_points()
    dlat = buffer_km / 111.0

    boxes = []
    for lon, lat in points:
        dlon = buffer_km / (111.0 * max(0.1, abs(math.cos(math.radians(lat)))))
        boxes.append([lon - dlon, lat - dlat, lon + dlon, lat + dlat])

    merged = True
    while merged:
        merged = False
        out = []
        for box in boxes:
            for kept in out:
                if _overlaps(kept, box):
                    candidate = [
                        min(kept[0], box[0]), min(kept[1], box[1]),
                        max(kept[2], box[2]), max(kept[3], box[3]),
                    ]
                    if (candidate[2] - candidate[0] <= max_span_deg
                            and candidate[3] - candidate[1] <= max_span_deg):
                        kept[:] = candidate
                        merged = True
                        break
            else:
                out.append(list(box))
        boxes = out

    return [tuple(round(v, 5) for v in b) for b in boxes], len(points)


def _overlaps(a, b):
    return not (a[2] < b[0] or b[2] < a[0] or a[3] < b[1] or b[3] < a[1])


# --------------------------------------------------------------------------
# Time chunking
# --------------------------------------------------------------------------


def parse_iso(value):
    """Accept either a bare date or a full CMR-style timestamp."""
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%d"):
        try:
            return datetime.strptime(value, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    raise SystemExit(f"Cannot parse date {value!r}; use YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ")


def to_cmr_time(value):
    return parse_iso(value).strftime("%Y-%m-%dT%H:%M:%SZ")


def chunk_window(start, end, months):
    """Split [start, end) into ~`months`-long ISO windows."""
    if months <= 0:
        return [(start, end)]
    t0, t1 = parse_iso(start), parse_iso(end)
    windows = []
    cur = t0
    while cur < t1:
        year, month = cur.year, cur.month + months
        year += (month - 1) // 12
        month = (month - 1) % 12 + 1
        nxt = min(cur.replace(year=year, month=month, day=1, hour=0, minute=0, second=0), t1)
        windows.append((cur.strftime("%Y-%m-%dT%H:%M:%SZ"), nxt.strftime("%Y-%m-%dT%H:%M:%SZ")))
        cur = nxt
    return windows


# --------------------------------------------------------------------------
# Downloader
# --------------------------------------------------------------------------


def find_downloader(explicit=None):
    """Locate the podaac-data-downloader executable."""
    if explicit:
        if not Path(explicit).exists():
            raise SystemExit(f"--downloader {explicit} does not exist")
        return explicit

    sibling = Path(__file__).resolve().parent / "envs" / "swot-dl" / "bin" / "podaac-data-downloader"
    if sibling.exists():
        return str(sibling)

    found = shutil.which("podaac-data-downloader")
    if found:
        return found

    raise SystemExit(
        "podaac-data-downloader not found. Install it with:\n"
        f"  python3 -m venv {Path(__file__).resolve().parent / 'envs' / 'swot-dl'}\n"
        f"  {Path(__file__).resolve().parent / 'envs' / 'swot-dl' / 'bin' / 'pip'} install podaac-data-subscriber\n"
        "or pass --downloader /path/to/podaac-data-downloader"
    )


def check_netrc():
    """Fail early and loudly if Earthdata credentials are not set up."""
    netrc = Path(os.environ.get("NETRC", Path.home() / ".netrc"))
    if netrc.exists() and EARTHDATA_HOST in netrc.read_text():
        return
    raise SystemExit(
        f"\nNo Earthdata Login credentials found in {netrc}.\n\n"
        "1. Register (free) at https://urs.earthdata.nasa.gov/users/new\n"
        f"2. Create {netrc} containing:\n\n"
        f"     machine {EARTHDATA_HOST}\n"
        "         login <your-username>\n"
        "         password <your-password>\n\n"
        f"3. chmod 600 {netrc}\n"
    )


def build_command(downloader, bbox, start, end, output_dir, resolution, dry_run, verbose):
    cmd = [
        downloader,
        "-c", SHORT_NAME,
        "-d", str(output_dir),
        "-sd", start,
        "-ed", end,
        # -b needs the = form so argparse does not read a leading "-" as a flag
        f"-b={','.join(str(v) for v in bbox)}",
        "-dy",          # year subdirectories under Data/SWOT/
        "-e", RESOLUTIONS[resolution]["ext"],
    ]
    if dry_run:
        cmd.append("--dry-run")
    if verbose:
        cmd.append("--verbose")
    return cmd


def run_task(cmd, label, log_dir):
    log_path = log_dir / f"{label}.log"
    with open(log_path, "w") as log:
        log.write(" ".join(cmd) + "\n\n")
        log.flush()
        proc = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT)
    return label, proc.returncode, log_path


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------


def main():
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--extent", choices=["ny", "ghg"], default="ny",
                   help="ny = whole New York State bbox (default); "
                        "ghg = buffered boxes around Data/FieldData/GHG sites")
    p.add_argument("--resolution", choices=["100m", "250m", "both"], default="100m",
                   help="grid sampling to fetch (default: 100m)")
    p.add_argument("-sd", "--start-date", default=DEFAULT_START,
                   help=f"ISO start (default: {DEFAULT_START})")
    p.add_argument("-ed", "--end-date", default=DEFAULT_END,
                   help=f"ISO end (default: {DEFAULT_END})")
    p.add_argument("-d", "--output-dir", default=str(DEFAULT_OUTPUT),
                   help=f"destination (default: {DEFAULT_OUTPUT})")
    p.add_argument("--report", action="store_true",
                   help="query CMR and print granule counts / GB, then exit")
    p.add_argument("--dry-run", action="store_true",
                   help="run the downloader in --dry-run mode (lists, downloads nothing)")
    p.add_argument("-j", "--jobs", type=int, default=4,
                   help="concurrent downloader processes (default: 4)")
    p.add_argument("--chunk-months", type=int, default=3,
                   help="split the time range into N-month windows (default: 3); "
                        "0 disables chunking")
    p.add_argument("--buffer-km", type=float, default=10.0,
                   help="[--extent ghg] buffer around each site (default: 10)")
    p.add_argument("--downloader", default=None,
                   help="path to podaac-data-downloader")
    p.add_argument("--verbose", action="store_true")
    args = p.parse_args()

    # Normalise so "2023-01-01" and the full timestamp form both work.
    args.start_date = to_cmr_time(args.start_date)
    args.end_date = to_cmr_time(args.end_date)

    if args.extent == "ny":
        bboxes, note = [NY_BBOX], "New York State bbox"
    else:
        bboxes, n_pts = ghg_bboxes(buffer_km=args.buffer_km)
        note = f"{len(bboxes)} boxes around {n_pts} GHG sites (+{args.buffer_km:g} km)"

    print(f"Extent      : {args.extent} — {note}")
    print(f"Resolution  : {args.resolution}")
    print(f"Time range  : {args.start_date} -> {args.end_date}")
    print(f"Destination : {args.output_dir}")

    if args.report:
        report(bboxes, args.start_date, args.end_date, args.resolution)
        return 0

    check_netrc()
    downloader = find_downloader(args.downloader)
    print(f"Downloader  : {downloader}")

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    log_dir = output_dir / "logs"
    log_dir.mkdir(exist_ok=True)

    windows = chunk_window(args.start_date, args.end_date, args.chunk_months)
    tasks = []
    for bi, bbox in enumerate(bboxes):
        for wstart, wend in windows:
            label = f"box{bi:03d}_{wstart[:7]}"
            tasks.append((
                build_command(downloader, bbox, wstart, wend, output_dir,
                              args.resolution, args.dry_run, args.verbose),
                label,
            ))

    print(f"Tasks       : {len(tasks)} ({len(bboxes)} box(es) x {len(windows)} window(s)), "
          f"{args.jobs} at a time")
    print(f"Logs        : {log_dir}\n")

    failures = []
    done = 0
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = [pool.submit(run_task, cmd, label, log_dir) for cmd, label in tasks]
        for future in as_completed(futures):
            label, code, log_path = future.result()
            done += 1
            # A window with no granules is still rc 0 (the downloader just finds
            # nothing to do), so a non-zero code is a genuine failure.
            status = "ok" if code == 0 else f"rc={code}"
            print(f"[{done}/{len(tasks)}] {label} {status}")
            if code != 0:
                failures.append((label, log_path))

    files = list(output_dir.rglob("*.nc"))
    total = sum(f.stat().st_size for f in files) / (1024 ** 3)
    print(f"\n{len(files)} .nc files in {output_dir} ({total:.1f} GB)")

    if failures:
        print(f"\n{len(failures)} task(s) failed — check the logs, then re-run the "
              f"same command (finished files are skipped by checksum):")
        for label, log_path in failures[:20]:
            print(f"  {label}: {log_path}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
