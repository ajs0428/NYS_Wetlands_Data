# NYS Wetlands Data

### Overview

Processes raw remote-sensing sources into analysis-ready data for wetland
mapping across New York State. It produces three things for the modelling
projects:

- **Per-HUC12 predictor rasters** (terrain, hydrology, canopy height, NAIP,
  leaf-off ortho, lidar structure), used for inference
- **Training patches** (256 × 256 px, predictor bands + a `MOD_CLASS` label band)
- **Global min/max band statistics** (JSON) for normalization

Consumers:

| Project | What it is | What it takes from here |
|---|---|---|
| `../NYS_Wetlands_DL` | Factorial benchmark, **frozen at tag `factorial-v3`** | `R_Patches`, `R_Patches_NWI`, `R_Patches_NWIextra`, `R_Patches_NWIextra10`; factorial stats JSON; all 7 per-HUC sources |
| `../NYS_Wetlands_Prod` | Production U-Net (active) | `R_Patches_Prod`; prod stats JSON; 5 per-HUC sources (no ortho/lidar); `Shell_Scripts/batch_config.sh` |
| `../NYS_Wetlands_GHG` | Dormant | predictor/prediction extractions at GHG field points |

`Documentation/Script_Dependency_Report.md` lists which scripts each project
depends on and which are archive candidates.

### Data organization

- All data are stored on a remote server (BioHPC at Cornell University)
- Datasets are organized and subset into **clusters** of **HUC12** watersheds across NY State
  - The organizing vector polygons are stored in Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg
    - `cluster` = cluster of HUC12 watersheds (6-12ish)
    - `huc` = single HUC12 watershed
  - Typically data will be named with `cluster_NUMBER_huc_HUCNUMBER_METRIC.tif`
  - Clusters are grouped into 18 disjoint batches (`batch1`–`batch18`) in
    `Shell_Scripts/batch_config.sh`; together they cover clusters 1–250 once

**Note** there were some edits made to these watersheds to fit the extent of the project. Some might not match the boundaries of the original HUC12 dataset

### Data

The authoritative band recipe is `R_Code_Analysis/huc_stack.R` — stacks are
assembled in memory and never written to disk. It defines two **stack profiles**:

| Profile | Used by | Sources (stack order) | NAIP bands |
|---|---|---|---|
| `factorial` (default) | `NYS_Wetlands_DL` | DEM, terrain, hydro, CHM, NAIP, ortho, lidar | `r g b nir` (`ndvi`/`ndwi` dropped) |
| `prod` | `NYS_Wetlands_Prod` | DEM, terrain, hydro, CHM, NAIP | `r g b nir ndvi ndwi` |

The profile is chosen by the `HUC_STACK_PROFILE` env var, otherwise by the patch
vector folder (`R_Patches_Vector_Prod/` and `R_Patches_Vector_Inference/` → `prod`),
otherwise `factorial`.

Sources:

- Terrain: Elevation - 'DEM', Slope/Gradient - 'slope_local', Topographic position index - 'TPI_local', Geomorphons categories - 'Geomorph_local', Mean curvature - 'meanc_local', Deviation from mean elevation - 'dmv_local'
  - Digital elevation model (DEM) rasters are [downloaded from the NYS GIS Clearinghouse](https://data.gis.ny.gov/) via FTP into Data/DEMs/ (manual, one-time per region; no automated download script exists yet)
  - `DEM_Extract_singleVect_CMD.R` collects and crops to the HUC12 raster
  - `terrain_metrics_filter_singleVect_CMD.R` writes **one** combined terrain raster per HUC — `cluster_<n>_huc_<id>_terrain_slp_local.tif`, bands `slope_local, TPI_local, Geomorph_local, meanc_local, dmv_local`, all five of which go into the stack. Slope/TPI come from `terra::terrain`, landforms from `rgeomorphon::geomorphons`, mean curvature from `MultiscaleDTM::Qfit(metrics = "meanc")`, and deviation from mean elevation from `MultiscaleDTM::DMV`
  - `DMV` runs at a **21×21** cell window (~21 m on a 1 m DEM), not the 3×3 the old `dmv` metric used: at 3×3 it was numerically identical to TPI (r = 1.0000 on a test HUC). At 21×21 the two are independent — `TPI_local` is fine-scale pit/peak roughness, `dmv_local` is position relative to the surrounding ~20 m. TPI was dropped at stack time before 2026-07 for exactly this redundancy; it is kept now. Window sizes are the `CURV_W`/`DMV_W` constants at the top of the script
  - As of 2026-07 there is no multiscale filtering: every metric is computed directly on the HUC DEM (the 5/100/500 m aggregate→resample scales are gone; the `_local` suffix is kept only because the downstream filename filters key on it). Plan (`planc`) and profile (`profc`) curvature are deliberately not produced
  - The step skips a HUC only when the existing file's band names match the contract, so terrain rasters written before 2026-07 are rebuilt automatically; `FORCE_TERRAIN=1` rebuilds everything
- Hydrology: Flow accumulation - 'flowacc' (log-transformed at stack time), Topographic wetness index - 'twi'
  - From the same digital elevation models: `hydro_metrics_singleVect_CMD.R` calculates flow accumulation and TWI
- Vegetation: Beier et al,. Canopy Height - 'CHM'
  - [Colin Beier from SUNY ESF created a canopy height model for all of NY State](10.1080/01431161.2022.2155086)
  - `CHM_extraction.R` extracts and crops to a HUC12 (resampled onto the HUC DEM)
- Lidar Vegetation (`factorial` profile only): % below 1m - 'pct_below_1m',  % above 1m but below 5m - 'pct_1m_to_5m',  % above 5m - 'pct_above_5m'
  - Collection tile indexes come from the NYS elevation REST service: `download_lidar_indexes.R` pulls them into Data/Lidar/Indexes/, and `build_lidar_index.R` merges them into the combined index Data/Lidar/NYS_Lidar_All_Indexes.gpkg (re-run both when a new collection is published)
  - Lidar point clouds are processed in memory (not stored) using `LIDAR_ftp.R`, which selects every tile in the combined index overlapping the cluster, and saves 1m metric rasters to Data/Lidar/Metrics/
  - `Lidar_HUC_Processing.R` collects and crops the processed rasters to a HUC12
- NAIP Imagery (leaf on): raw bands - 'r', 'g', 'b', 'nir', plus 'ndvi', 'ndwi'
  - 2017 NAIP tiles from NOAA Digital Coast (Data/NAIP/noaa_digital_coast_2017/) are used because they were collected more consistently across NY State in the growing season
  - `NAIP_Processing_CMD.R` collects and crops to a HUC12 (resampled onto the HUC DEM). `ndvi`/`ndwi` are written to the raster; the `factorial` profile drops them at stack time and the `prod` profile keeps them
- NYS Ortho Imagery (leaf off, `factorial` profile only): raw bands - 'r_lo', 'g_lo', 'b_lo', 'nir_lo'
  - `Ortho_ftp.R` queries the NYS ortho index REST service and downloads/reprojects tiles to Data/Ortho/Tiles/. The requested year (ORTHO_YEAR in `Shell_Scripts/batch_config.sh`, currently 2024) is the *preferred* year; where a cluster has no coverage for it, the nearest available year fills the gap automatically
  - `gdaltindex_ortho.sh` rebuilds the tile footprint index (Data/Ortho/ortho_tiles.gpkg) — must run after every download batch, before the HUC step (`step_ortho_index.sh` does this inside the SLURM chain)
  - `Ortho_HUC_Processing.R` mosaics, crops, and aligns to a HUC12's DEM, preferring a single year per HUC and gap-filling with the nearest year (years used are written to the GeoTIFF metadata)
  - Ortho imagery is stored in JPG2000 format, which the BioHPC GDAL cannot read — `ortho_gdalwarp.sh` wraps a JP2-capable conda gdalwarp (see comments in that file)
  - `ortho_huc_qa.sh` (`Ortho_HUC_QA.R`) reports per-HUC coverage, NA, zero and dark fractions inside the HUC polygon

**Dropped from the pipeline (2026-06):** Sentinel satellite indices (`step_sat_gee.sh`)
— their outputs are not part of the `huc_stack.R` band contract. The scripts live
in `Shell_Scripts/archive/`. The GEE notebooks in `Python_Code_Analysis/` date
from the same period and are not used by the current pipeline.

**Restored 2026-07:** mean curvature and DMV, dropped alongside the satellite
indices in 2026-06, are back — but as extra *bands* of the existing `slp` terrain
stage rather than the separate `curv`/`dmv` metrics they used to be. There is
still exactly one terrain job in the dependency graph, and `step_terrain.sh` now
rejects `curv`/`dmv` as metric arguments. Plan/profile curvature and the
multiscale filtering were not restored.

**In development (2026-11):** Height Above Nearest Drainage — `step_hand.sh`
(`hydro_HAND.R`) writes Data/TerrainProcessed/HUC_HAND/ from the hydro stage's
outputs. It is not in `huc_stack.R`, so neither model reads it yet.

## Pipeline 1 — per-HUC predictor rasters (shared by DL and Prod)

All per-cluster processing is submitted by **one entry point** that wires the
SLURM dependency chain (DEM first; everything that aligns to the HUC DEMs waits
for it):

```bash
# cluster numbers, batch names from batch_config.sh, or a mix
bash Shell_Scripts/step_combined_master.sh 225
bash Shell_Scripts/step_combined_master.sh "208,225,11"
bash Shell_Scripts/step_combined_master.sh batch1
bash Shell_Scripts/step_combined_master.sh "batch7,batch8,225"

# print the sbatch graph without submitting
DRYRUN=1 bash Shell_Scripts/step_combined_master.sh batch1

# one stage only (checks its upstream outputs on disk first)
bash Shell_Scripts/step_combined_master.sh batch2 hydro
# stages: dem slp hydro chm naip lidar_ftp lidar ortho_dl ortho_index ortho_huc check

# skip the download stages when tiles already cover the clusters
SKIP_LIDAR_FTP=1 SKIP_ORTHO_DL=1 bash Shell_Scripts/step_combined_master.sh 225

# Prod-only clusters: drop the lidar and ortho branches entirely
SKIP_LIDAR=1 SKIP_ORTHO=1 bash Shell_Scripts/step_combined_master.sh batch9
```

Dependency graph (`afterok` unless noted):

```
dem ──┬── terrain slp (slope/TPI/geomorphons/meanc/dmv)
      ├── hydro (flowacc/twi)
      ├── chm
      ├── naip
      └──────────────────────────────┐
lidar_ftp ──── lidar_huc             │      (afterany: the ftp stage is resumable)
ortho_dl ───── ortho_index ──── ortho_huc
      (everything) ──── check   (afterany; missing-output report + CSV)
```

| Stage | Output folder (under Data/) | DL | Prod |
|---|---|---|---|
| dem | TerrainProcessed/HUC_DEMs | ✔ | ✔ |
| slp | TerrainProcessed/HUC_TerrainMetrics | ✔ | ✔ |
| hydro | TerrainProcessed/HUC_Hydro | ✔ | ✔ |
| chm | CHMs/HUC_CHMs | ✔ | ✔ |
| naip | NAIP/HUC_NAIP_Processed | ✔ | ✔ |
| lidar_ftp, lidar | Lidar/Metrics, Lidar/HUC_Lidar_Metrics | ✔ | – |
| ortho_dl, ortho_index, ortho_huc | Ortho/Tiles, Ortho/HUC_Ortho | ✔ | – |

Shared settings (cluster gpkg, ORTHO_YEAR, lidar index, batch definitions) live
in `Shell_Scripts/batch_config.sh`.

All stages run in the **`R256C128` partition** (nodes `cbsuxu09`–`cbsuxu10`, 128 CPU /
~256 GB each); each `step_*.sh` pins `--partition=R256C128 --nodelist=cbsuxu09,cbsuxu10`.
A SLURM job can't span partitions, so don't mix in `R128C40` (`cbsuxu01`–`08`) nodes.
The one exception is the terrain stage, which `TERRAIN_PARTITION=R128C40` sends to
`cbsuxu01`–`08` as its own job.

Readiness checks:

```bash
# fast filesystem check per HUC across the 7 sources (+ terrain band names);
# also writes a <name>_valid_pairs.txt of ready cluster:huc pairs
bash Shell_Scripts/check_stack_ready.sh batch1
bash Shell_Scripts/check_stack_ready.sh all --no-bands
```

`check_stack_ready.sh` always tests all seven sources. A HUC that is missing only
`ortho` and/or `lidar` is still ready for the `prod` profile.

## Pipeline 2 — training data for `NYS_Wetlands_DL` (factorial-v3, frozen)

Profile `factorial`: 20 predictor bands + `MOD_CLASS`. Four patch folders with an
identical band schema; the label source is the folder. This pipeline only needs
rerunning to reproduce or extend the factorial.

```
reviewed vectors                    R_Patches_Vector_Reviewed/   (field + GIS-reviewed; source of truth)
   ├─ nwi_in_patch_extract.sh       → R_Patches_Vector_NWI/        NWI labels on the same footprints
   └─ nwiextra_in_patch_extract.sh  → R_Patches_Vector_NWIextra/   1x extra NWI patches in the same HUC12s
        (preset x10)                → R_Patches_Vector_NWIextra10/ 8x more; spills to stack-ready HUCs

check_patch_vectors.sh <vector dir>            report what will rasterize (read-only)
raster_chipspatches_dl.sh <vector dir>         → R_Patches/, R_Patches_NWI/, R_Patches_NWIextra/, R_Patches_NWIextra10/
dl_extract_normalize_stats.sh (factorial)      → Data/HUC_Raster_Stacks/HUC_DL_Stacks_Extracted_Values.json
```

```bash
# 1. NWI label arms (login node, minutes). Add 1 as the first arg to rebuild.
bash Shell_Scripts/nwi_in_patch_extract.sh
bash Shell_Scripts/nwiextra_in_patch_extract.sh            # 1x set
bash Shell_Scripts/nwiextra_in_patch_extract.sh 1 x10      # 10x arm; needs the 1x set first

# 2. Check, then rasterize each vector folder (default folder = reviewed)
bash   Shell_Scripts/check_patch_vectors.sh
sbatch Shell_Scripts/raster_chipspatches_dl.sh
sbatch Shell_Scripts/raster_chipspatches_dl.sh Data/Training_Data/R_Patches_Vector_NWI/
sbatch Shell_Scripts/raster_chipspatches_dl.sh Data/Training_Data/R_Patches_Vector_NWIextra/
sbatch Shell_Scripts/raster_chipspatches_dl.sh Data/Training_Data/R_Patches_Vector_NWIextra10/ 0 vectors

# 3. Global min/max over the factorial stack
HUC_STACK_PROFILE=factorial sbatch Shell_Scripts/dl_extract_normalize_stats.sh batch1 batch2 batch3
```

Hand-off (manual copy; no script does this):

- the four `Data/Training_Data/R_Patches*/` folders → `../NYS_Wetlands_DL/Data/Training_Data/`
- `HUC_DL_Stacks_Extracted_Values.json` → `../NYS_Wetlands_DL/Data/Training_Data/`
- inference source rasters are pulled per HUC by DL's `Shell_Scripts/rsync_huc_sources.sh`
  (`--pairs` takes the `_valid_pairs.txt` from `check_stack_ready.sh`)

The JSON currently in `Data/HUC_Raster_Stacks/` (2026-08-26) is newer than the
copy the frozen factorial trained with (2026-08-17). Don't overwrite the DL copy.

## Pipeline 3 — training data for `NYS_Wetlands_Prod` (active)

Profile `prod`: DEM, 5 terrain, 2 hydro, CHM, 6 NAIP bands + `MOD_CLASS`. One
vector folder (`R_Patches_Vector_Prod/`) and one patch folder (`R_Patches_Prod/`),
both of which grow in place. Every vector file is GIS-reviewed in QGIS before it
goes into `R_Patches_Vector_Prod/`.

```
sources of new patch vectors
   ├─ R_Patches_Vector_Reviewed/                        the factorial's reviewed set
   ├─ vector_chipspatches_fromraw_dl.sh                 → R_Patches_Vector_fromRAW/   (NWI, NYS Informational, NYC wetlands)
   ├─ inference_chipspatches_dl.sh                      → R_Patches_Vector_Inference/ (squares over DL/Prod prediction rasters)
   └─ field GPS (FieldGPS_to_PatchVectors.R)            → R_Patches_Vector_Field/
            │
            ▼  review in QGIS, save the reviewed gpkg into
   R_Patches_Vector_Prod/
            │
check_patch_vectors.sh  → raster_chipspatches_dl.sh     → R_Patches_Prod/
dl_extract_normalize_stats.sh (prod, default)           → Data/HUC_Raster_Stacks/HUC_DL_Stacks_Extracted_Values_prod.json
```

```bash
# 1. Candidate patch vectors (pick the source you need)
sbatch Shell_Scripts/vector_chipspatches_fromraw_dl.sh \
    Data/Laba_NYS_Info_Wetlands/Informational_Freshwater_Wetland_Mapping_-4832045112583547805.gpkg \
    BINARY NONE batch1,batch2
sbatch Shell_Scripts/inference_chipspatches_dl.sh        # default: DL v3 masked predictions, 25 per HUC

# 2. Review in QGIS, save into Data/Training_Data/R_Patches_Vector_Prod/

# 3. Check, then rasterize. "vectors" = every cluster that has a gpkg in the folder
bash   Shell_Scripts/check_patch_vectors.sh    Data/Training_Data/R_Patches_Vector_Prod/ vectors
sbatch Shell_Scripts/raster_chipspatches_dl.sh Data/Training_Data/R_Patches_Vector_Prod/ 0 vectors
#   after EDITING existing vectors, pass 1 instead of 0 to rebuild those HUCs' patches

# 4. Global min/max over the prod stack (all 18 batches by default)
sbatch Shell_Scripts/dl_extract_normalize_stats.sh
```

Notes:

- Binary (`_BINARY`) vector files rasterize `WET` as code 4 and `UPL` as 3, so
  `UPL` is 3 in every patch.
- The prod stats JSON is only read by Prod's legacy `global_minmax` recipes;
  current `p1p99` recipes scale from the patches. Rerun step 4 only if a
  `global_minmax` recipe is needed or the band recipe changes.
- `dl_extract_normalize_stats.sh` clears the profile's partials first, so pass
  every batch you want in one call (or use `RESUME=1`).

Hand-off:

- `Data/Training_Data/R_Patches_Prod/` → `../NYS_Wetlands_Prod/Data/Training_Data/` (manual copy)
- `HUC_DL_Stacks_Extracted_Values_prod.json` → same folder (manual copy)
- inference source rasters are pushed per batch by Prod's
  `Shell_Scripts/rsync_push_sources_prod.sh`, which reads `batch_config.sh` from
  this repo. Renaming or renumbering batches here changes what Prod pushes.
- Adding patches starts a new data generation in Prod (new master stats, new
  split, new recipes) — see step B in the Prod README.

## Checklist

1. Confirm the HUC12 cluster file (`GPKG` in `Shell_Scripts/batch_config.sh`) and
   the batches cover the clusters you need.
2. One-time prerequisites per data refresh:
   - DEM source tiles for the clusters exist in Data/DEMs/ (manual download)
     with `NYS_All_DEM_Index.gpkg`
   - CHM (Data/CHMs/AWS/) and NAIP 2017 (Data/NAIP/noaa_digital_coast_2017/)
     source tiles are present
   - Lidar indexes are current (`factorial` profile only):
     `Rscript R_Code_Analysis/download_lidar_indexes.R` then
     `Rscript R_Code_Analysis/build_lidar_index.R`
3. Submit Pipeline 1: `bash Shell_Scripts/step_combined_master.sh <clusters|batchN>`
   (add `SKIP_LIDAR=1 SKIP_ORTHO=1` for Prod-only clusters).
4. Check the final `pipeline_check` job. It exits non-zero if any HUC is missing
   any of the seven sources and writes a per-HUC CSV to Shell_Scripts/logs/.
   With `SKIP_LIDAR`/`SKIP_ORTHO` it will report those sources as missing; that
   is expected. `bash Shell_Scripts/check_stack_ready.sh <selection>` gives the
   same answer in seconds and also checks the terrain band names.
5. Build or update patch vectors (Pipeline 2 or 3), and GIS-review them.
6. `bash Shell_Scripts/check_patch_vectors.sh <vector dir> [clusters]` — fix
   anything it flags (empty geometries, reused `PatchGroup` ids, HUC-edge boxes)
   before spending SLURM time.
7. Rasterize: `sbatch Shell_Scripts/raster_chipspatches_dl.sh <vector dir> [REMOVE_EXISTING] [CLUSTERS]`.
   Use `REMOVE_EXISTING=1` after editing vectors; existing patches are otherwise skipped.
8. Global min/max, if needed: `sbatch Shell_Scripts/dl_extract_normalize_stats.sh`
   (`prod` by default; `HUC_STACK_PROFILE=factorial` for DL). Rerun whenever the
   band recipe in `huc_stack.R` changes.
9. Copy the patch folder(s) and stats JSON into the consumer project's
   `Data/Training_Data/`, then follow that project's README (normalization
   stats, splits, training and inference happen there, not here).
