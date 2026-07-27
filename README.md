# NYS Wetlands Data

### Overview

Processing “raw” data sources into analysis ready datasets.

Outputs should include: 

- Processed predictor data for wetland mapping models
- Training data in patches/chips

### Data organization

- All data are stored on a remote server (BioHPC at Cornell University)
- Datasets are organized and subset into **clusters** of **HUC12** watersheds across NY State
  - The organizing vector polygons are stored in Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg
    - `cluster` = cluster of HUC12 watersheds (6-12ish)
    - `huc` = single HUC12 watershed
  - Typically data will be named with `cluster_NUMBER_huc_HUCNUMBER_METRIC.tif`

**Note** there were some edits made to these watersheds to fit the extent of the project. Some might not match the boundaries of the original HUC12 dataset

### Data 

As of 6/10/2026 Metrics needed for wetland mapping model (the authoritative band
recipe is `R_Code_Analysis/huc_stack.R` — stacks are assembled in memory, never
written to disk): 

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
- Lidar Vegetation: % below 1m - 'pct_below_1m',  % above 1m but below 5m - 'pct_1m_to_5m',  % above 5m - 'pct_above_5m'
  - Collection tile indexes come from the NYS elevation REST service: `download_lidar_indexes.R` pulls them into Data/Lidar/Indexes/, and `build_lidar_index.R` merges them into the combined index Data/Lidar/NYS_Lidar_All_Indexes.gpkg (re-run both when a new collection is published)
  - Lidar point clouds are processed in memory (not stored) using `LIDAR_ftp.R`, which selects every tile in the combined index overlapping the cluster, and saves 1m metric rasters to Data/Lidar/Metrics/
  - `Lidar_HUC_Processing.R` collects and crops the processed rasters to a HUC12
- NAIP Imagery (leaf on): raw bands - 'r', 'g', 'b', 'nir'
  - NAIP imagery is downloaded from Google Earth Engine to Google cloud storage or NOAA Digital Coast
    - Currently 2017 NAIP from NOAA digital coast is used because it has been collected more consistently across NY State in the growing season
    - The GEE script is a python script: `GEE_HUC_Indices.ipynb`
  - `NAIP_Processing_CMD.R` collects and crops to a HUC12 (resampled onto the HUC DEM; ndvi/ndwi are written but dropped at stack time)
- NYS Ortho Imagery (leaf off): raw bands - 'r_lo', 'g_lo', 'b_lo', 'nir_lo'
  - `Ortho_ftp.R` queries the NYS ortho index REST service and downloads/reprojects tiles to Data/Ortho/Tiles/. The requested year (ORTHO_YEAR in `Shell_Scripts/batch_config.sh`, currently 2024) is the *preferred* year; where a cluster has no coverage for it, the nearest available year fills the gap automatically
  - `gdaltindex_ortho.sh` rebuilds the tile footprint index (Data/Ortho/ortho_tiles.gpkg) — must run after every download batch, before the HUC step (`step_ortho_index.sh` does this inside the SLURM chain)
  - `Ortho_HUC_Processing.R` mosaics, crops, and aligns to a HUC12's DEM, preferring a single year per HUC and gap-filling with the nearest year (years used are written to the GeoTIFF metadata)
  - Ortho imagery is stored in JPG2000 format, which the BioHPC GDAL cannot read — `ortho_gdalwarp.sh` wraps a JP2-capable conda gdalwarp (see comments in that file)

**Dropped from the pipeline (2026-06):** Sentinel satellite indices (`step_sat_gee.sh`)
— their outputs are not part of the `huc_stack.R` band contract. The scripts live
in `Shell_Scripts/archive/`.

**Restored 2026-07:** mean curvature and DMV, dropped alongside the satellite
indices in 2026-06, are back — but as extra *bands* of the existing `slp` terrain
stage rather than the separate `curv`/`dmv` metrics they used to be. There is
still exactly one terrain job in the dependency graph, and `step_terrain.sh` now
rejects `curv`/`dmv` as metric arguments. Plan/profile curvature and the
multiscale filtering were not restored.

## Running the pipeline

All per-cluster processing is submitted by **one entry point** that wires the
SLURM dependency chain (DEM first; everything that aligns to the HUC DEMs waits
for it):

```bash
# one or more clusters, or a batch name from batch_config.sh
bash Shell_Scripts/step_combined_master.sh 225
bash Shell_Scripts/step_combined_master.sh "208,225,11"
bash Shell_Scripts/step_combined_master.sh batch1

# print the sbatch graph without submitting
DRYRUN=1 bash Shell_Scripts/step_combined_master.sh batch1

# skip the download stages when tiles already cover the clusters
SKIP_LIDAR_FTP=1 SKIP_ORTHO_DL=1 bash Shell_Scripts/step_combined_master.sh 225
```

Dependency graph (all `afterok` unless noted):

```
dem ──┬── terrain slp (slope/TPI/geomorphons/meanc/dmv)
      ├── hydro (flowacc/twi)
      ├── chm
      ├── naip
      └──────────────────────────────┐
lidar_ftp ──── lidar_huc             │
ortho_dl ───── ortho_index ──── ortho_huc
      (everything) ──── check   (afterany; missing-output report + CSV)
```

Shared settings (cluster gpkg, ORTHO_YEAR, batch definitions) live in
`Shell_Scripts/batch_config.sh`.

All stages run in the **`R256C128` partition** (nodes `cbsuxu09`–`cbsuxu10`, 128 CPU /
~256 GB each); each `step_*.sh` pins `--partition=R256C128 --nodelist=cbsuxu09,cbsuxu10`.
A SLURM job can't span partitions, so don't mix in `R128C40` (`cbsuxu01`–`08`) nodes.

### Checklist

1. Make sure the HUC12 watershed file is appropriate
2. One-time prerequisites per data refresh:
   - DEM source tiles for the clusters exist in Data/DEMs/ (manual download)
   - Lidar indexes are current: `Rscript R_Code_Analysis/download_lidar_indexes.R`
     then `Rscript R_Code_Analysis/build_lidar_index.R`
3. Submit the pipeline: `bash Shell_Scripts/step_combined_master.sh <clusters|batchN>`
4. Check the final `pipeline_check` job (fails if any HUC is missing any of the
   seven sources; per-HUC CSV in Shell_Scripts/logs/)
5. Process training data patches
   - For vector files: `Vector_ChipsPatches_DL.R`
   - For raster files (model inputs): `Raster_ChipsPatches_DL.R`
6. Transfer patches and band stats to GPU accelerated computer to train model and predict new maps
