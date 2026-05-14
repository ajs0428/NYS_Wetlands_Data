# NYS Wetlands Data

### Overview

Processing “raw” data sources into analysis ready datasets
Inputs

- Downloaded datasets
 
Outputs should include: 

- Processed Wetland Map Sources to be viewed in GIS 
- Training data in patches/chips
- Raster stacks for mapping model predictions

### Data 

As of 5/11/2026 input data include: 

- DEM
- Slope
- Geomorphons
- Flow Accumulation
- TWI
- CHM
- NAIP (RGBN)
- Lidar (% below 1m, % 1-5m, % above 5m)

All are 1m resolution

### Checklist

1. Make sure HUC12 watershed file is appropriate 
2. Extract DEMs for target HUC12 watersheds
  - `DEM_Extract_singleVect_CMD.r`
  - `step_dem.sh`
3. Process terrain metrics 
  - `terrain_metrics_noparallel_filter_singleVect_CMD`
  - `step_terrain.sh`
4. Process hydrology metrics
  - `hydro_metrics_singleVect_CMD.r`
  - `step_hydro.sh`
5. Extract Canopy Height (Beier et al.,)
  - `CHM_extraction.R`
  - `step_chm.sh`
6. Extract NAIP imagery
  - `NAIP_Processing_CMD.R`
  - `step_naip.sh`
7. Download and process Lidar vegetation metrics
  - `LIDAR_ftp.R`
  - `LIDAR_HUC_Processing.R`
  - `step_lidar.sh` <- only after ftp download
8. Align and create raster stacks (TBD on keeping this due to data duplication)
 - `Raster_Stack.R`
9. Process training data patches
 - For vector files: `Vector_ChipsPatches.R`
 - For raster files (model inputs): `Raster_ChipsPatches_DL.R`
10. Transfer raster stacks and patches to GPU accelerated computer to train model and predict new maps
