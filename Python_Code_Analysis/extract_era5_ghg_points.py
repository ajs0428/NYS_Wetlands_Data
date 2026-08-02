#!/usr/bin/env python3
"""Extract ERA5-Land + WorldClim climate data for the NY GHG field points, locally.

Python port of the Earth Engine JavaScript script ``ERA5_Climate_Extraction``.
Same computation — for each point, ERA5-Land daily aggregates are summarised over
the 1 / 7 / 14 / 28 days *preceding* that point's sample date (mean for every
variable, sum for precipitation) and sampled at the point — but instead of
``Export.table.toDrive`` the table is pulled straight down and written under
``Data/FieldData/GHG/``.

Windows are half-open ``[date - N days, date)``, exactly as
``ee.Filter.date(start, pointDate)`` behaves in the JS. One deliberate
difference: each date is truncated to UTC midnight first, so a window is always
whole days strictly *before* the sample day. The uploaded asset stores Date as
epoch millis at midnight **Eastern** (07:00 UTC), so the JS export's windows were
shifted 7 h and included the sample day's own aggregate; ``--no-floor-dates``
reproduces that.

Units are ERA5-Land's own, left unconverted so the CSV matches what the JS export
produced: temperatures in K, ``surface_pressure`` in Pa, precipitation in m,
``volumetric_soil_water_layer_1`` in m3/m3, winds in m/s. ``--plots`` converts to
degC / mm for display only.

On top of that, each point also gets **WorldClim BIO V1 climate normals**
(``WORLDCLIM/V1/BIO``, 1960-1990, 30 arc-sec), by default ``bio01`` (annual mean
temperature) and ``bio12`` (annual precipitation). These are one static image, so
they are sampled once per point with no time window — the same value every visit
to a site. Unlike the ERA5 columns these *are* unit-converted, because the V1
asset stores temperatures as integer tenths of a degree; the output column name
carries the unit, e.g. ``bio01_C`` = 7.3 degC, ``bio12_mm`` = 980 mm.
``--worldclim bio01,bio05,bio12`` picks other bands, ``--worldclim none`` skips
them.

Outputs (``--prefix`` renames all three):
    NYDEC_GHG_Sites_ERA5.csv
    NYDEC_GHG_Sites_ERA5.gpkg          (--no-gpkg to skip)
    NYDEC_GHG_Sites_ERA5_climate.png   (--plots)

Authentication, in order: an explicit ``--key``, then any service-account JSON in
``Python_Code_Analysis/API_Key/``, then ordinary user credentials from
``earthengine authenticate``. The service-account route is what works
non-interactively on BioHPC.

Needs the ``gee-env`` conda env (earthengine-api, pandas, geopandas, matplotlib):

    /workdir/ajs544/miniconda3/envs/gee-env/bin/python \\
        Python_Code_Analysis/extract_era5_ghg_points.py

Examples
--------
    # Default: the uploaded EE asset, 1/7/14/28-day windows, CSV + GeoPackage
    python extract_era5_ghg_points.py

    # Use the local GeoPackage instead (untruncated column names) and draw the
    # CH4-vs-climate scatters the JS script printed as ui.Charts
    python extract_era5_ghg_points.py \\
        --source Data/FieldData/GHG/NYDEC_GHG_Sites_6347.gpkg --plots

    # Fewer/other windows; more BIO bands; ERA5 only
    python extract_era5_ghg_points.py --windows 7,30,90
    python extract_era5_ghg_points.py --worldclim bio01,bio05,bio06,bio12
    python extract_era5_ghg_points.py --worldclim none
"""

from __future__ import annotations

import argparse
import glob
import sys
import time
from pathlib import Path

import ee

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------

PROJECT_ROOT = Path(__file__).resolve().parent.parent
KEY_DIR = Path(__file__).resolve().parent / "API_Key"
DEFAULT_OUT = PROJECT_ROOT / "Data" / "FieldData" / "GHG"

EE_PROJECT = "earthengineajs"
DEFAULT_SOURCE = "projects/earthengineajs/assets/NY_GHG_Sites_shp"

ERA5_ID = "ECMWF/ERA5_LAND/DAILY_AGGR"
ERA5_SCALE = 11132  # nominal ERA5-Land resolution, metres

# Mean over the window for these...
MEAN_BANDS = [
    "temperature_2m",
    "u_component_of_wind_10m",
    "v_component_of_wind_10m",
    "surface_pressure",
    "volumetric_soil_water_layer_1",
    "soil_temperature_level_1",
]
# ...and a sum for this one.
PRECIP_BAND = "total_precipitation_sum"

# Output column order within each window, matching the JS .set() order.
BAND_ORDER = [
    "temperature_2m",
    PRECIP_BAND,
    "u_component_of_wind_10m",
    "v_component_of_wind_10m",
    "surface_pressure",
    "volumetric_soil_water_layer_1",
    "soil_temperature_level_1",
]

DEFAULT_WINDOWS = [1, 7, 14, 28]

# WorldClim BIO V1 — 1960-1990 climate normals, one static image, 30 arc-sec.
# Date-independent, so it is sampled once per point with no time window.
WORLDCLIM_ID = "WORLDCLIM/V1/BIO"
WORLDCLIM_SCALE = 927.67  # nominal 30 arc-sec

# Band -> (multiplier, output-name suffix). The V1 asset stores temperatures as
# integer tenths of a degree, so bio01 = 70 means 7.0 degC; precipitation bands
# are already mm. bio03 / bio04 / bio15 are indices whose stored scaling is not
# stated on the asset itself, so they pass through raw and unsuffixed rather
# than risk a wrong factor.
WORLDCLIM_BANDS = {
    "bio01": (0.1, "_C"),    # annual mean temperature
    "bio02": (0.1, "_C"),    # mean diurnal range
    "bio03": (1.0, ""),      # isothermality (index)
    "bio04": (1.0, ""),      # temperature seasonality (index)
    "bio05": (0.1, "_C"),    # max temperature of warmest month
    "bio06": (0.1, "_C"),    # min temperature of coldest month
    "bio07": (0.1, "_C"),    # temperature annual range
    "bio08": (0.1, "_C"),    # mean temperature of wettest quarter
    "bio09": (0.1, "_C"),    # mean temperature of driest quarter
    "bio10": (0.1, "_C"),    # mean temperature of warmest quarter
    "bio11": (0.1, "_C"),    # mean temperature of coldest quarter
    "bio12": (1.0, "_mm"),   # annual precipitation
    "bio13": (1.0, "_mm"),   # precipitation of wettest month
    "bio14": (1.0, "_mm"),   # precipitation of driest month
    "bio15": (1.0, ""),      # precipitation seasonality (index)
    "bio16": (1.0, "_mm"),   # precipitation of wettest quarter
    "bio17": (1.0, "_mm"),   # precipitation of driest quarter
    "bio18": (1.0, "_mm"),   # precipitation of warmest quarter
    "bio19": (1.0, "_mm"),   # precipitation of coldest quarter
}
DEFAULT_WORLDCLIM = ["bio01", "bio12"]

# Candidate attribute names for the wetland-class grouping used by --plots.
# The shapefile-derived asset truncates to 10 characters.
WETLAND_FIELDS = ("Wetland_Type", "Wetland_Ty")

ROW_KEY = "_era5_row"  # internal join key when the source is a local file


# --------------------------------------------------------------------------
# Auth
# --------------------------------------------------------------------------


def initialize(key=None, project=EE_PROJECT):
    """Initialize Earth Engine, preferring a service account over user creds."""
    candidates = [Path(key)] if key else sorted(Path(p) for p in glob.glob(str(KEY_DIR / "*.json")))
    if key and not candidates[0].exists():
        raise SystemExit(f"--key {key} does not exist")

    # Keys that are revoked, or belong to a service account without EE access,
    # fail here; only report them if nothing at all works.
    failures = []
    for path in candidates:
        try:
            creds = ee.ServiceAccountCredentials(None, str(path))
            ee.Initialize(creds, project=project)
            print(f"Earth Engine: service account {path.name}")
            return
        except Exception as exc:
            failures.append(f"  {path.name}: {exc}")

    try:
        ee.Initialize(project=project)
        print("Earth Engine: user credentials")
    except Exception as exc:
        failures.append(f"  user credentials: {exc}")
        raise SystemExit(
            "Could not initialize Earth Engine:\n" + "\n".join(failures) + "\n\n"
            f"Either put a working service-account key in {KEY_DIR} (or pass --key), "
            "or run `earthengine authenticate` once for this account."
        )


# --------------------------------------------------------------------------
# The extraction (direct port of extractERA5 from the JS)
# --------------------------------------------------------------------------


def worldclim_image(bands):
    """Scaled WorldClim BIO image, bands renamed to carry their units."""
    names = worldclim_columns(bands)
    factors = [WORLDCLIM_BANDS[b][0] for b in bands]
    return (ee.Image(WORLDCLIM_ID)
            .select(bands, names)
            .multiply(ee.Image.constant(factors).rename(names)))


def worldclim_columns(bands):
    """Output names for the requested bands; also validates the band list."""
    unknown = [b for b in bands if b not in WORLDCLIM_BANDS]
    if unknown:
        raise SystemExit(
            f"Unknown WorldClim band(s) {', '.join(unknown)}; choose from "
            f"{', '.join(sorted(WORLDCLIM_BANDS))}"
        )
    return [f"{b}{WORLDCLIM_BANDS[b][1]}" for b in bands]


def build_extractor(date_field, windows, scale, floor_dates=True,
                    worldclim=None, worldclim_scale=WORLDCLIM_SCALE):
    era5 = ee.ImageCollection(ERA5_ID).select(MEAN_BANDS + [PRECIP_BAND])
    wc_image = worldclim_image(worldclim) if worldclim else None
    wc_names = worldclim_columns(worldclim) if worldclim else []

    def extract(feature):
        feature = ee.Feature(feature)
        point_date = ee.Date(feature.get(date_field))
        if floor_dates:
            # Truncate to UTC midnight. The asset's Date is epoch millis at
            # midnight *Eastern* (07:00 UTC), so without this the window runs
            # [D-1 07:00, D 07:00) and captures the daily aggregate of the
            # sample day itself, while a local file's naive midnight gives
            # [D-1 00:00, D 00:00). Flooring makes every window whole days
            # strictly before the sample day, identically for both sources.
            point_date = ee.Date(point_date.format("YYYY-MM-dd"))
        geom = feature.geometry()

        out = feature
        for days in windows:
            start = point_date.advance(-days, "day")
            window = era5.filter(ee.Filter.date(start, point_date)).filterBounds(geom)

            # Mean for everything, sum for precipitation, then one sample.
            combined = window.select(MEAN_BANDS).mean().addBands(
                window.select([PRECIP_BAND]).sum()
            )
            values = combined.reduceRegion(
                reducer=ee.Reducer.first(), geometry=geom, scale=scale
            )

            for band in BAND_ORDER:
                out = out.set(f"{band}_{days}d", values.get(band))
            out = out.set(f"start_date_{days}d", start.format("YYYY-MM-dd"))

        out = out.set("end_date", point_date.format("YYYY-MM-dd"))

        if wc_image is not None:
            wc_values = wc_image.reduceRegion(
                reducer=ee.Reducer.first(), geometry=geom, scale=worldclim_scale
            )
            for name in wc_names:
                out = out.set(name, wc_values.get(name))

        return out

    return extract


def era5_columns(windows):
    cols = []
    for days in windows:
        cols += [f"{band}_{days}d" for band in BAND_ORDER]
        cols.append(f"start_date_{days}d")
    return cols + ["end_date"]


def added_columns(windows, worldclim=None):
    """Every column this script appends, in output order."""
    return era5_columns(windows) + (worldclim_columns(worldclim) if worldclim else [])


def fetch(fc, extract, chunk_size=25, retries=4):
    """Map `extract` over `fc` and pull the properties down in chunks.

    Chunking keeps each request well inside EE's compute timeout; a single
    getInfo over the whole collection is one long request that either all
    succeeds or all fails.
    """
    n = fc.size().getInfo()
    print(f"Points      : {n}")
    if n == 0:
        raise SystemExit("Source collection is empty")

    features = fc.toList(n)
    rows = []
    for offset in range(0, n, chunk_size):
        size = min(chunk_size, n - offset)
        chunk = ee.FeatureCollection(features.slice(offset, offset + size)).map(extract)

        for attempt in range(1, retries + 1):
            try:
                info = chunk.getInfo()
                break
            except ee.EEException as exc:
                if attempt == retries:
                    raise SystemExit(
                        f"Chunk at offset {offset} failed after {retries} attempts: {exc}"
                    )
                wait = 2 ** attempt
                print(f"  offset {offset}: {exc} — retry {attempt}/{retries - 1} in {wait}s",
                      file=sys.stderr)
                time.sleep(wait)

        for feat in info["features"]:
            row = dict(feat.get("properties") or {})
            geom = feat.get("geometry") or {}
            if geom.get("type") == "Point":
                row["longitude"], row["latitude"] = geom["coordinates"][:2]
            rows.append(row)

        print(f"  {min(offset + size, n)}/{n} points")

    return rows


# --------------------------------------------------------------------------
# Sources
# --------------------------------------------------------------------------


def load_source(source, date_field):
    """Return (FeatureCollection, GeoDataFrame or None).

    An EE asset id is used as-is, so every attribute rides along into the output
    just as in the JS. A local vector file is uploaded as bare points keyed by
    row index — only the date is sent — and the attributes are re-joined locally
    afterwards, which keeps the original CRS and untruncated column names.
    """
    path = Path(source)
    if not path.exists():
        return ee.FeatureCollection(source), None

    import geopandas as gpd
    import pandas as pd

    gdf = gpd.read_file(path)
    if date_field not in gdf.columns:
        raise SystemExit(f"{path} has no {date_field!r} column; columns: {list(gdf.columns)}")
    if gdf.geometry.geom_type.ne("Point").any():
        raise SystemExit(f"{path} contains non-point geometries")

    gdf = gdf.reset_index(drop=True)
    gdf[ROW_KEY] = gdf.index
    wgs84 = gdf.to_crs("EPSG:4326")
    dates = gdf[date_field]

    features = []
    for i, (geom, stamp) in enumerate(zip(wgs84.geometry, dates)):
        if pd.isna(stamp):
            raise SystemExit(f"Row {i} has no {date_field}; fix the source or drop the row")
        millis = int(stamp.value // 10**6) if hasattr(stamp, "value") else int(stamp)
        features.append(
            ee.Feature(ee.Geometry.Point([geom.x, geom.y]),
                       {ROW_KEY: i, date_field: millis})
        )

    print(f"Source      : {path} ({len(features)} points, {gdf.crs})")
    return ee.FeatureCollection(features), gdf


# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------


def assemble(rows, windows, gdf, date_field, worldclim=None):
    """Build the output table: source attributes, then the extracted columns."""
    import pandas as pd

    era5 = pd.DataFrame(rows)
    new_cols = [c for c in added_columns(windows, worldclim) if c in era5.columns]

    if gdf is None:
        base = [c for c in era5.columns if c not in new_cols and c not in ("longitude", "latitude")]
        table = era5[base + new_cols + ["longitude", "latitude"]]
        geometry = None
    else:
        era5 = era5.set_index(ROW_KEY).sort_index()
        missing = set(gdf[ROW_KEY]) - set(era5.index)
        if missing:
            raise SystemExit(f"{len(missing)} rows came back without ERA5 values: {sorted(missing)[:10]}")
        table = gdf.drop(columns=[ROW_KEY]).join(era5[new_cols])
        geometry = gdf.geometry
        table = pd.DataFrame(table.drop(columns=[table.geometry.name]))

    # Human-readable date column alongside the raw one, which is epoch millis
    # for the asset route.
    if date_field in table.columns and "end_date" in table.columns:
        table.insert(table.columns.get_loc(date_field) + 1, "sample_date", table["end_date"])

    return table, geometry


def write_outputs(table, geometry, gdf, out_dir, prefix, want_gpkg):
    out_dir.mkdir(parents=True, exist_ok=True)
    written = []

    csv_path = out_dir / f"{prefix}.csv"
    table.to_csv(csv_path, index=False)
    written.append(csv_path)

    if want_gpkg:
        try:
            import geopandas as gpd
        except ImportError:
            print("geopandas not available — skipping the GeoPackage", file=sys.stderr)
        else:
            if geometry is not None:
                out = gpd.GeoDataFrame(table, geometry=geometry.values, crs=gdf.crs)
            else:
                out = gpd.GeoDataFrame(
                    table,
                    geometry=gpd.points_from_xy(table["longitude"], table["latitude"]),
                    crs="EPSG:4326",
                )
            gpkg_path = out_dir / f"{prefix}.gpkg"
            out.to_file(gpkg_path, driver="GPKG")
            written.append(gpkg_path)

    return written


# --------------------------------------------------------------------------
# Plots — the four ui.Charts from the JS, as one PNG
# --------------------------------------------------------------------------

# Validated categorical slots 1-3 (blue / orange / aqua). Three classes is the
# all-pairs-safe cap for scatter, which is why these group by wetland class
# rather than by Site_ID: 48 sites cannot be told apart by hue.
SERIES_COLORS = ["#2a78d6", "#eb6834", "#1baf7a"]
SURFACE = "#fcfcfb"
INK = "#0b0b0b"
INK_2 = "#52514e"
GRID = "#e8e7e3"
AXIS = "#c9c8c3"


def plot(table, windows, out_dir, prefix):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.dates as mdates
    import matplotlib.pyplot as plt
    import pandas as pd

    short = windows[0]  # the JS charts used the 1-day window
    mid = windows[1] if len(windows) > 1 else windows[0]

    needed = [f"temperature_2m_{short}d", f"total_precipitation_sum_{short}d",
              f"volumetric_soil_water_layer_1_{short}d", f"total_precipitation_sum_{mid}d"]
    if "CH4_avg" not in table.columns or any(c not in table.columns for c in needed):
        print("Not enough columns for --plots (need CH4_avg + ERA5 values) — skipping",
              file=sys.stderr)
        return None

    df = table.copy()
    df["CH4_avg"] = pd.to_numeric(df["CH4_avg"], errors="coerce")
    df["_date"] = pd.to_datetime(df["end_date"])
    df["_temp_c"] = pd.to_numeric(df[f"temperature_2m_{short}d"], errors="coerce") - 273.15
    df["_precip_mm"] = pd.to_numeric(df[f"total_precipitation_sum_{short}d"], errors="coerce") * 1000
    df["_precip_mm_mid"] = pd.to_numeric(df[f"total_precipitation_sum_{mid}d"], errors="coerce") * 1000
    df["_vsw"] = pd.to_numeric(df[f"volumetric_soil_water_layer_1_{short}d"], errors="coerce")

    group_col = next((c for c in WETLAND_FIELDS if c in df.columns), None)
    groups = sorted(df[group_col].dropna().unique()) if group_col else []
    if len(groups) > len(SERIES_COLORS):
        groups, group_col = [], None  # fold to one series rather than cycle hues

    fig, axes = plt.subplots(2, 2, figsize=(11, 8.2), dpi=200, facecolor=SURFACE)
    panels = [
        ("_date", "_precip_mm_mid", f"{mid}-day precipitation before sampling",
         "Sample date", f"Precipitation, {mid} d sum (mm)"),
        ("_precip_mm", "CH4_avg", f"CH4 flux vs {short}-day precipitation",
         f"Precipitation, {short} d sum (mm)", "CH4 flux (CH4_avg)"),
        ("_temp_c", "CH4_avg", f"CH4 flux vs {short}-day air temperature",
         f"Air temperature, {short} d mean (°C)", "CH4 flux (CH4_avg)"),
        ("_vsw", "CH4_avg", f"CH4 flux vs {short}-day soil moisture",
         f"Soil water layer 1, {short} d mean (m³/m³)", "CH4 flux (CH4_avg)"),
    ]

    for ax, (xcol, ycol, title, xlab, ylab) in zip(axes.ravel(), panels):
        ax.set_facecolor(SURFACE)
        ax.set_title(title, color=INK, fontsize=11, loc="left", pad=8)
        ax.set_xlabel(xlab, color=INK_2, fontsize=9)
        ax.set_ylabel(ylab, color=INK_2, fontsize=9)
        ax.grid(True, color=GRID, linewidth=0.6, zorder=0)
        ax.set_axisbelow(True)
        for side in ("top", "right"):
            ax.spines[side].set_visible(False)
        for side in ("left", "bottom"):
            ax.spines[side].set_color(AXIS)
        ax.tick_params(colors=INK_2, labelsize=8, length=3, color=AXIS)

        subsets = ([(g, df[df[group_col] == g]) for g in groups] if groups
                   else [(None, df)])
        for (label, sub), color in zip(subsets, SERIES_COLORS):
            ax.scatter(sub[xcol], sub[ycol], s=55, color=color, label=label,
                       edgecolor=SURFACE, linewidth=1.2, zorder=3)

        if xcol == "_date":
            ax.xaxis.set_major_formatter(mdates.DateFormatter("%b %Y"))
            for lbl in ax.get_xticklabels():
                lbl.set_rotation(30)
                lbl.set_horizontalalignment("right")

    if groups:
        handles, labels = axes[0][0].get_legend_handles_labels()
        legend = fig.legend(handles, labels, loc="upper right", ncol=len(labels),
                            frameon=False, fontsize=9,
                            bbox_to_anchor=(0.995, 0.995),
                            title=group_col.replace("_", " "))
        legend.get_title().set_color(INK_2)
        legend.get_title().set_fontsize(9)
        for text in legend.get_texts():
            text.set_color(INK)

    fig.suptitle("NY GHG field sites — ERA5-Land climate before sampling",
                 color=INK, fontsize=13, x=0.02, ha="left", y=0.985)
    fig.tight_layout(rect=(0, 0, 1, 0.93))
    png = out_dir / f"{prefix}_climate.png"
    fig.savefig(png, facecolor=SURFACE)
    plt.close(fig)
    return png


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------


def main():
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument("--source", default=DEFAULT_SOURCE,
                   help="EE asset id, or a path to a local point vector file "
                        f"(default: {DEFAULT_SOURCE})")
    p.add_argument("--date-field", default="Date",
                   help="attribute holding each point's sample date (default: Date)")
    p.add_argument("--windows", default=",".join(str(w) for w in DEFAULT_WINDOWS),
                   help="comma-separated lookback windows in days "
                        f"(default: {','.join(str(w) for w in DEFAULT_WINDOWS)})")
    p.add_argument("--scale", type=int, default=ERA5_SCALE,
                   help=f"sampling scale in metres (default: {ERA5_SCALE})")
    p.add_argument("-d", "--out-dir", default=str(DEFAULT_OUT),
                   help=f"destination directory (default: {DEFAULT_OUT})")
    p.add_argument("--prefix", default="NYDEC_GHG_Sites_ERA5",
                   help="output basename (default: NYDEC_GHG_Sites_ERA5)")
    p.add_argument("--chunk-size", type=int, default=25,
                   help="points per getInfo request (default: 25)")
    p.add_argument("--worldclim", default=",".join(DEFAULT_WORLDCLIM),
                   help="comma-separated WorldClim BIO V1 bands to sample as climate "
                        f"normals (default: {','.join(DEFAULT_WORLDCLIM)}); "
                        "'none' or an empty value skips WorldClim entirely")
    p.add_argument("--worldclim-scale", type=float, default=WORLDCLIM_SCALE,
                   help=f"WorldClim sampling scale in metres (default: {WORLDCLIM_SCALE})")
    p.add_argument("--no-floor-dates", action="store_true",
                   help="use each Date's raw timestamp instead of truncating it to "
                        "UTC midnight; reproduces the JS export exactly, where "
                        "midnight-Eastern timestamps let the sample day into the window")
    p.add_argument("--no-gpkg", action="store_true", help="write only the CSV")
    p.add_argument("--plots", action="store_true",
                   help="also render the CH4-vs-climate scatters as a PNG")
    p.add_argument("--key", default=None, help="service-account JSON key")
    p.add_argument("--project", default=EE_PROJECT,
                   help=f"Earth Engine cloud project (default: {EE_PROJECT})")
    args = p.parse_args()

    windows = [int(w) for w in args.windows.split(",") if w.strip()]
    if not windows:
        raise SystemExit("--windows produced no values")
    worldclim = [] if args.worldclim.strip().lower() in ("", "none") else [
        b.strip() for b in args.worldclim.split(",") if b.strip()
    ]
    out_dir = Path(args.out_dir)

    initialize(args.key, args.project)
    fc, gdf = load_source(args.source, args.date_field)
    if gdf is None:
        print(f"Source      : {args.source} (EE asset)")
    print(f"Windows     : {', '.join(f'{w} d' for w in windows)} before each sample date"
          f"{'' if args.no_floor_dates else ' (UTC-midnight day boundary)'}")
    print(f"Dataset     : {ERA5_ID} @ {args.scale} m")
    if worldclim:
        print(f"Normals     : {WORLDCLIM_ID} @ {args.worldclim_scale:g} m — "
              f"{', '.join(worldclim_columns(worldclim))}")
        unscaled = [b for b in worldclim if WORLDCLIM_BANDS.get(b, (1.0,))[0] == 1.0
                    and not WORLDCLIM_BANDS.get(b, (1.0, ""))[1]]
        if unscaled:
            print(f"              {', '.join(unscaled)} left as stored — check the "
                  "catalog scaling before using them as physical units")
    print(f"Destination : {out_dir}")

    rows = fetch(fc, build_extractor(args.date_field, windows, args.scale,
                                     floor_dates=not args.no_floor_dates,
                                     worldclim=worldclim,
                                     worldclim_scale=args.worldclim_scale),
                 chunk_size=args.chunk_size)
    table, geometry = assemble(rows, windows, gdf, args.date_field, worldclim)

    written = write_outputs(table, geometry, gdf, out_dir, args.prefix, not args.no_gpkg)
    if args.plots:
        png = plot(table, windows, out_dir, args.prefix)
        if png:
            written.append(png)

    print(f"\n{len(table)} rows x {len(table.columns)} columns")
    for path in written:
        print(f"  {path}")

    added = [c for c in added_columns(windows, worldclim) if c in table.columns]
    coverage = table[added].notna().mean()
    if coverage.min() < 1.0:
        thin = coverage[coverage < 1.0]
        print("\nNote: some extracted columns are incomplete — points near the end of "
              "the ERA5-Land record (it lags ~5 days) or on pixels the source masks "
              "(open water, for WorldClim) come back empty:")
        for name, frac in thin.sort_values().items():
            print(f"  {name}: {frac:.0%} filled")
    return 0


if __name__ == "__main__":
    sys.exit(main())
