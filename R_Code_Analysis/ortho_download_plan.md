# Plan: NYS Orthoimagery Download Script (`Ortho_ftp.R`)

## Goal

Write an R script that downloads NYS Digital Orthoimagery Program (NYSDOP) tiles overlapping a set of HUC12 watersheds (defined by cluster number), extracts `.jp2` files from downloaded zips, and reprojects them to EPSG:6347. The script should parallel the structure of the existing `Lidar_ftp.R` pipeline (attached below for reference) and run on Cornell BioHPC via SLURM.

---

## Data Source Architecture

### ArcGIS REST MapServer — Tile Index

The NYS orthoimagery tile indexes live on an ArcGIS MapServer:

```
https://orthos.its.ny.gov/arcgis/rest/services/vector/ortho_indexes/MapServer
```

Each **layer** in the service is a polygon feature class covering one year/zone/resolution/band-type combination. The naming convention is:

```
indYYZ_resolution_bands
```

Where:
- `YY` = two-digit year (e.g., `20` = 2020, `23` = 2023)
- `Z` = NY State Plane zone: `e` (east), `c` (central), `w` (west), `l` (long island)
- `resolution` = `half_ft`, `one_ft`, `two_ft`, `one_m`
- `bands` = `4bd` (4-band), `color` (natural color), `cir` (color infrared)

Examples of available layers and their IDs (VERIFIED against the live service, ArcGIS 10.81, 157 layers, 2026-05-24):
| Layer ID | Name | Description |
|----------|------|-------------|
| 0 | `ind25e_half_ft_4bd` | 2025, east zone, 0.5-ft, 4-band |
| 1 | `ind25c_half_ft_4bd` | 2025, central zone, 0.5-ft, 4-band |
| 8 | `ind23e_half_ft_4bd` | 2023, east zone, 0.5-ft, 4-band |
| 10 | `ind23c_one_ft_4bd` | 2023, central zone, 1-ft, 4-band |
| 13 | `ind22c_one_ft_4bd` | 2022, central zone, 1-ft, 4-band |
| 22 | `ind20e_one_ft_4bd` | 2020, east zone, 1-ft, 4-band |
| 23 | `ind20c_one_ft_4bd` | 2020, central zone, 1-ft, 4-band |
| 24 | `ind20w_one_ft_4bd` | 2020, west zone, 1-ft, 4-band |

> ⚠️ **Do not hardcode layer IDs.** The IDs above were corrected after the original
> draft was found to be off (e.g., `ind20e_one_ft_4bd` is layer **22**, not 21).
> IDs shift as new years are published. Always resolve layer IDs at runtime by name
> (see "Determining Which Index Layer(s) to Query"). The service also carries `color`
> and `cir` band variants in addition to `4bd`.

**Fields per feature** (VERIFIED from live query of layers 22 & 23, 2020):
- `OBJECTID` — unique row ID
- `FILENAME` — tile filename string, **includes the file extension and has inconsistent case**
  across layers (e.g., layer 22 returns `e_03361900_12_19000_4bd_2020.jp2` lowercase, layer 23
  returns `c_05010728_12_19000_4bd_2020.jP2` mixed-case). Must normalize: lowercase + strip
  extension before dedup, skip-if-exists checks, and output naming.
- `FTP_PATH` — partial FTP path, e.g. `ortho/nysdop9/st_lawrence/spcs/tiles`
- `DIRECT_DL` — full HTTPS download URL to a zip on `gisdata.ny.gov` (confirmed populated for 2020)
- `Shape_Area` — polygon area in map units. **Full ortho tiles are ~1.0–1.1 million m² (~1 km²),
  NOT 2.25M m² like the LiDAR tiles.** Calibrate any partial-tile area filter accordingly.
- `Shape` / `Shape_Length` — geometry fields

**Key constraints:**
- `MaxRecordCount: 1000` — queries return at most 1000 features. Must paginate using `resultOffset` for larger result sets.
- Spatial reference is EPSG:3857 (Web Mercator) on the server. Can request `outSR=4326` or `outSR=6347` in queries.
- Supports spatial queries (`geometry`, `geometryType=esriGeometryEnvelope`, `spatialRel=esriSpatialRelIntersects`).

**Query endpoint pattern:**
```
https://orthos.its.ny.gov/arcgis/rest/services/vector/ortho_indexes/MapServer/{LAYER_ID}/query
```

With parameters:
- `where=1=1` (or a filter expression)
- `geometry={xmin},{ymin},{xmax},{ymax}` — bounding box
- `geometryType=esriGeometryEnvelope`
- `inSR=4326` (or whatever CRS the bbox is in)
- `spatialRel=esriSpatialRelIntersects`
- `outFields=FILENAME,FTP_PATH,DIRECT_DL,Shape_Area`
- `returnGeometry=true`
- `outSR=6347` (request geometry in target CRS)
- `f=geojson` (returns GeoJSON directly readable by `sf::st_read()`)
- `resultOffset=N` (for pagination)
- `resultRecordCount=1000`

### FTP / HTTPS Download Structure

The `DIRECT_DL` field contains an HTTPS URL pointing to a **zip file** on `gisdata.ny.gov`. The VERIFIED pattern (from live 2020 queries) is:

```
https://gisdata.ny.gov/ortho/{program_folder}/{county}/spcs/tiles/{filename}.zip
```

(Note: `/spcs/tiles/`, **not** `/spcs/zips/` as an earlier draft assumed. Since the script uses
`DIRECT_DL` verbatim this is informational, but don't reconstruct URLs from the wrong template.)

Where `program_folder` varies by NYSDOP cycle:
- `nysdop10` → 2023 imagery
- `nysdop9` → 2020 imagery  
- `nysdop8` → 2018 imagery
- `nysdop7` → 2015 imagery
- `nysdop6` → 2012 imagery
- `nysdop3` → 2007 imagery

**Important:** The municipality-level zips (e.g., `twn_Danby_sp23.zip`) on the county download pages are **different** from the tile-level zips referenced in `DIRECT_DL`. The tile index `DIRECT_DL` field points to individual tile zips, not municipality bundles. The script should use `DIRECT_DL` directly.

Equivalent FTP URLs can be constructed by replacing `https://gisdata.ny.gov/` → `ftp://ftp.gis.ny.gov/` (same pattern used in the LiDAR script).

### Zip Contents

Each tile zip contains 3 files:
```
e_04922188_12_19000_4bd_2020.aux    # Auxiliary metadata
e_04922188_12_19000_4bd_2020.j2w    # World file (georeferencing)
e_04922188_12_19000_4bd_2020.jp2    # JPEG2000 raster (the actual imagery)
```

The `.jp2` is the target file. The `.j2w` world file is useful if the JP2 lacks internal georeferencing, but typically the JP2 has embedded CRS info.

---

## Determining Which Index Layer(s) to Query

A key difference from the LiDAR script: the LiDAR pipeline takes a local tile index GPKG as a parameter, but the ortho tile indexes are hosted on the REST service and organized by **state plane zone**. A given HUC12 cluster could span multiple state plane zones (east/central boundary runs roughly along ~76°W longitude through central NY).

**Approach — query by bounding box, let the script determine zones automatically:**

1. The script should accept a `year` parameter (e.g., `2020`) and a `bands` parameter (e.g., `4bd`).
2. Compute the bounding box of the cluster's HUC12 polygons in EPSG:4326.
3. Look up which layer IDs correspond to that year/bands combo. This requires either:
   - (a) A hardcoded lookup table mapping year+zone+resolution+bands → layer ID, OR
   - (b) Querying the MapServer root to list all layers and parsing names at runtime.
   
   **Recommendation:** Option (b) is more robust. Query `https://orthos.its.ny.gov/arcgis/rest/services/vector/ortho_indexes/MapServer?f=json`, parse the `layers` array, filter by year and bands in the layer name. This handles future years automatically.

4. Query **all matching layers** for that year (e.g., for 2020 4-band: layers for east, central, west, long island zones) using the HUC12 cluster bounding box as a spatial filter. The spatial filter naturally returns only tiles that overlap, so querying extra zones that don't overlap costs nothing.

5. Combine results across zones, deduplicate by `FILENAME`.

---

## Script Structure

### Command-Line Arguments

```
Rscript Ortho_ftp.R <gpkg_path> <cluster_number> <year> <output_dir> [bands]
```

- `gpkg_path` — path to HUC12 cluster zones GPKG (same as LiDAR script: `NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg`)
- `cluster_number` — cluster ID to filter HUC12s
- `year` — imagery year (e.g., `2020`)
- `output_dir` — where to write final `.tif` files
- `bands` — optional, defaults to `4bd`

### Dependencies

```r
library(curl)        # FTP/HTTPS downloads
library(stringr)     # String manipulation
library(sf)          # Spatial operations, reading GeoJSON from REST API
library(dplyr)       # Data wrangling
library(terra)       # Raster I/O, reprojection
library(jsonlite)    # Parsing MapServer JSON responses
library(future)
library(future.apply)
```

### Function Outline

#### 1. `get_ortho_layer_ids(year, bands)`

- Fetches `https://orthos.its.ny.gov/arcgis/rest/services/vector/ortho_indexes/MapServer?f=json`
- Parses the `layers` array from the JSON response
- Filters to layers matching `ind{YY}*_{bands}` pattern (where `YY` = last two digits of year)
- Returns a tibble of `layer_id` and `layer_name`

#### 2. `query_ortho_index(layer_id, bbox_4326)`

- Builds the REST query URL for a single layer using the bounding box as spatial filter
- Must handle **pagination**: loop with `resultOffset` incrementing by 1000 until fewer than 1000 features returned
- Requests `f=geojson` with `outFields=FILENAME,FTP_PATH,DIRECT_DL,Shape_Area` and `returnGeometry=true`
- Reads each page via `sf::st_read()` on the URL (or via `jsonlite::fromJSON()` + manual sf construction)
- Returns an sf object with all matching tile polygons

**Note on sf::st_read() with URLs:** `st_read()` can read GeoJSON from a URL directly. Build the full query URL including pagination params and pass it. If the URL is too long or causes issues, an alternative is to use `httr::GET()` / `curl_fetch_memory()` to download the JSON, write to a temp file, and read with `st_read()`.

#### 3. `get_overlapping_ortho_tiles(gpkg_path, cluster_num, year, bands)`

- Reads HUC12s for the cluster from the GPKG
- Computes bounding box in EPSG:4326
- Calls `get_ortho_layer_ids()` to find relevant layers
- Calls `query_ortho_index()` for each layer
- `bind_rows()` results, deduplicates by a **normalized** tile name (lowercase + strip extension),
  since `FILENAME` carries the extension and inconsistent case across zones
- Optionally: refine from bbox to actual polygon intersection (the bbox query is a coarse filter; some tiles at corners may not actually overlap any HUC12). Do this by transforming query results to the HUC12 CRS and running `st_intersects()`. This mirrors the LiDAR script's approach.
- Returns a tibble with `FILENAME`, `DIRECT_DL`, and geometry

#### 4. `download_ortho_tile(direct_dl_url, dest_dir)`

- Downloads the zip from `DIRECT_DL` URL using `curl::curl_download()`
- Falls back to FTP URL if HTTPS fails (replace `https://gisdata.ny.gov/` → `ftp://ftp.gis.ny.gov/`)
- Unzips to a temp directory
- Locates the `.jp2` file in the extracted contents
- Returns the path to the `.jp2`

#### 5. `reproject_ortho_tile(jp2_path, out_dir, target_crs = "EPSG:6347")`

- Reads the `.jp2` with `terra::rast()`
- **Resamples AND reprojects to 1 m EPSG:6347**, snapped to the same integer-meter grid as the
  LiDAR metrics, using `method = "bilinear"` (appropriate for continuous imagery).
- Writes as GeoTIFF to `out_dir` with filename derived from the normalized (lowercased,
  extension-stripped) tile name.
- Returns the output path

**Target resolution is 1 m, by design.** The ortho will be stacked as model input alongside the
1 m LiDAR vegetation-metrics rasters (EPSG:6347). The orthoimagery is collected under **leaf-off**
conditions, which complements the LiDAR canopy story. Native NYSDOP resolution is 0.5-ft or 1-ft;
we intentionally downsample to 1 m so the ortho aligns pixel-for-pixel with the LiDAR grid. This
means the grid-snapping logic copied from `Lidar_ftp.R` (floor/ceil the reprojected extent, build a
1 m template `rast()`, `project()` onto it) is exactly what we want here — it is NOT a bug.

**Resolution-consistency note:** a cluster spanning the east/central boundary can pull source tiles
of differing native resolution (e.g., 2023 east is `half_ft` but 2023 central is `one_ft`). Because
everything is resampled to 1 m, the mix is harmless — but **log a warning** when matched layers span
multiple native resolutions so the provenance is visible.

**Memory / HPC consideration:** a 1-ft 4-band tile is large (~3000×3000 px × 4 bands). Two options:
- `terra::project()` onto a 1 m template — handles large rasters via temp files, keeps everything in R.
- `gdalwarp` via `system()` — more memory-efficient on HPC, with `-tap` to enforce grid alignment:
  ```r
  system(paste("gdalwarp -t_srs EPSG:6347 -tr 1 1 -tap -r bilinear -of GTiff -overwrite",
               shQuote(jp2_path), shQuote(out_path)))
  ```
  The `terra` path is preferred for consistency with `Lidar_ftp.R`; switch to `gdalwarp` only if
  memory becomes a problem on BioHPC.

#### 6. `process_ortho_tile(filename, direct_dl_url, out_dir)`

- Top-level per-tile function (called in parallel)
- Checks if output `.tif` already exists (skip if so)
- Calls `download_ortho_tile()` → `reproject_ortho_tile()`
- Cleans up temp files (zip, extracted jp2)
- Returns output path or NULL on failure
- Wrapped in `tryCatch()` for fault tolerance

### Main Execution Flow

```
1. Parse command-line args
2. Read HUC12 cluster polygons from GPKG
3. Query REST API for overlapping tile indexes (handles pagination + multiple zones)
4. Deduplicate tiles, optionally filter by polygon intersection
5. Set up future plan (future.callr, pinned to SLURM_CPUS_PER_TASK)
6. future_lapply over tiles: download → unzip → reproject → write GeoTIFF
7. Report success/failure counts
```

### Parallelization

Same pattern as LiDAR script:
```r
n_workers <- as.integer(Sys.getenv("SLURM_CPUS_PER_TASK", unset = "1"))
if (n_workers > 1) {
    plan(future.callr::callr)
} else {
    plan(sequential)
}
```

---

## Key Differences from the LiDAR Script

| Aspect | LiDAR (`Lidar_ftp.R`) | Ortho (`Ortho_ftp.R`) |
|--------|----------------------|----------------------|
| Tile index source | Local GPKG file passed as arg | ArcGIS REST API queried at runtime |
| Download format | Raw `.las` files via FTP | `.zip` files via HTTPS (with FTP fallback) |
| Post-download step | Compute vegetation metrics (pixel_metrics) | Unzip → extract `.jp2` |
| Reprojection | Part of metrics computation | Standalone step (JP2 → GeoTIFF in EPSG:6347) |
| Output format | Multi-band metrics GeoTIFF | 4-band imagery GeoTIFF |
| Zone handling | Single index GPKG per run | Script auto-discovers zones from REST API |
| Resolution concern | 1m metrics output | Native resolution (0.5-ft or 1-ft); large files |

---

## Edge Cases & Error Handling

- **Pagination**: The REST API caps at 1000 records. The query function must loop. The robust
  signal is the `exceededTransferLimit: true` property in the response (VERIFIED present) — loop,
  incrementing `resultOffset`, until it is absent/false. Do not rely on count == `resultRecordCount`
  (fails on exact multiples). Note: `f=geojson` does not always echo `exceededTransferLimit`, so
  either page on a parallel `f=json` count, or fall back to "fewer than `resultRecordCount` returned".
- **Zone boundaries**: A cluster near ~76°W may span east/central zones. Querying all zones for the year handles this.
- **Missing tiles**: Some areas may have no coverage for a given year. Log warnings but don't fail.
- **Download failures**: FTP/HTTPS can be flaky. Implement retry logic (e.g., 3 attempts with backoff) in `download_ortho_tile()`.
- **Disk space**: JP2s and their zip containers can be large. Clean up zips and raw JP2s after reprojection.
- **GDAL JP2 driver**: Ensure GDAL on BioHPC has JP2 support (`JP2OpenJPEG` or `JP2ECW` driver). Can verify with `terra::gdal(drivers=TRUE)` or `sf::sf_extSoftVersion()`.

---

## Reference: Existing LiDAR Script

The full `Lidar_ftp.R` script is provided alongside this plan. The ortho script should mirror its overall structure, logging style, `tryCatch` patterns, parallel execution setup, and command-line argument handling.
