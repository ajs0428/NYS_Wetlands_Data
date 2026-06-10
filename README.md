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

As of 6/10/2026 Metrics needed for wetland mapping model: 

- Terrain: Elevation - 'DEM', Slope/Gradient - 'slope_local', Geomorphons categories - 'Geomorph_local', 
- Hydrology: Flow accumulation - 'flowacc', Topographic wetness index - 'twi', 
- Vegetation: Beier et al,. Canopy Height - 'CHM'
- Lidar Vegetation: % below 1m - 'pct_below_1m',  % above 1m but below 5m - 'pct_1m_to_5m',  % above 5m - 'pct_above_5m'
- NAIP Imagery (leaf on): raw bands - 'r', 'g', 'b', 'nir', 
- NYS Ortho Imagery (leaf off): raw bands - 'r_lo', 'g_lo', 'b_lo', 'nir_lo'


## Checklist

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
