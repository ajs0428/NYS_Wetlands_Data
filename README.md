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

As of 6/10/2026 Metrics needed for wetland mapping model: 

- Terrain: Elevation - 'DEM', Slope/Gradient - 'slope_local', Geomorphons categories - 'Geomorph_local'
  - Digital elevation model (DEM) rasters are [downloaded from the NYS GIS Clearinghouse](https://data.gis.ny.gov/) via FTP 
  - `DEM_Extract_singleVect_CMD.r` collects and crops to the HUC12 raster
  - `terrain_metrics_noparallel_filter_singleVect_CMD.R` calculates slope and Geomorphons categories
- Hydrology: Flow accumulation - 'flowacc', Topographic wetness index - 'twi'
  - From the same digital elevation models: `hydro_metrics_singleVect_CMD.R` calculates flow accumulation and TWI
- Vegetation: Beier et al,. Canopy Height - 'CHM'
  - [Colin Beier from SUNY ESF created a canopy height model for all of NY State](10.1080/01431161.2022.2155086)
  - `CHM_extraction.R` extracts and crops to a HUC12 
- Lidar Vegetation: % below 1m - 'pct_below_1m',  % above 1m but below 5m - 'pct_1m_to_5m',  % above 5m - 'pct_above_5m'
  - Lidar point clouds are processed in memory (not downloaded) using `LIDAR_ftp.R` and saved into 1m rasters
  - `LIDAR_HUC_Processing.R` collects and crops the processed rasters to a HUC12 
- NAIP Imagery (leaf on): raw bands - 'r', 'g', 'b', 'nir'
  - NAIP imagery is downloaded from Google Earth Engine to Google cloud storage or NOAA Digital Coast
    - Currently 2017 NAIP from NOAA digital coast is used because it has been collected more consistently across NY State in the growing season
    - The GEE script is a python script: `GEE_HUC_Indices.ipynb`
  - `NAIP_Processing_CMD.R` collects and crops to a HUC12
- NYS Ortho Imagery (leaf off): raw bands - 'r_lo', 'g_lo', 'b_lo', 'nir_lo'
  - Ortho imagery is processed similarly to Lidar that it is processed from an ftp script `Ortho_ftp.R` but now fully downloaded
  - `Ortho_HUC_Processing.R` collects and crops to a HUC12
  - Ortho imagery is also stored on the NYS GIS site in JPG2000 format which can cause some issues if GDAL is not fully updated 


## Checklist

- There are accompanying shell/bash scripts that execute processing on high memory HPC nodes using SLURM 

1. Make sure HUC12 watershed file is appropriate 
2. Extract DEMs for target HUC12 watersheds
  - `step_dem.sh`
3. Process terrain metrics 
  - `step_terrain.sh`
4. Process hydrology metrics
  - `step_hydro.sh`
5. Extract Canopy Height (Beier et al.,)
  - `step_chm.sh`
6. Extract NAIP imagery
  - `step_naip.sh`
7. Extract Ortho imagery
  - `ortho_gdalwarp.sh` - for jpg2000
  - `ortho_loop.sh`
  - `step_ortho.sh`
  - `step_ortho_huc.sh`
8. Download and process Lidar vegetation metrics
  - `lidar_loop.sh`
  - `lidar_huc_loop.sh`
  - `step_lidar.sh` <- only after ftp download
9. Process training data patches
 - For vector files: `Vector_ChipsPatches.R`
 - For raster files (model inputs): `Raster_ChipsPatches_DL.R`
10. Transfer raster stacks and patches to GPU accelerated computer to train model and predict new maps
