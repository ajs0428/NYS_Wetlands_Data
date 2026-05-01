#!/bin/bash -l

### All metric processing is sequential

module load R/4.4.3
cd /ibstorage/anthony/NYS_Wetlands_Data/

include=(225)

GPKG="Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg"

### Run DEM
for number in "${include[@]}"; do
    echo "Running Rscript with argument: $number"
    Rscript R_Code_Analysis/DEM_Extract_singleVect_CMD.r \
        "Data/NYS_DEM_Indexes" \
        "$GPKG" \
        "$number" \
        "Data/DEMs/" \
        "Data/TerrainProcessed/HUC_DEMs/"

done

### Run Curvature 
for number in "${include[@]}"; do
    echo "Running Rscript with argument: $number" 
    Rscript R_Code_Analysis/terrain_metrics_noparallel_filter_singleVect_CMD.r \
    "$number" \
    "Data/TerrainProcessed/HUC_DEMs" \
    "curv" \
    "Data/TerrainProcessed/HUC_TerrainMetrics/"
    
done

### Run Slope 
for number in "${include[@]}"; do
    echo "Running Rscript with argument: $number" 
    Rscript R_Code_Analysis/terrain_metrics_noparallel_filter_singleVect_CMD.r \
    "$number" \
    "Data/TerrainProcessed/HUC_DEMs" \
    "slp" \
    "Data/TerrainProcessed/HUC_TerrainMetrics/"
    
done

### Run DMV 
for number in "${include[@]}"; do
    echo "Running Rscript with argument: $number" 
    Rscript R_Code_Analysis/terrain_metrics_noparallel_filter_singleVect_CMD.r \
    "$number" \
    "Data/TerrainProcessed/HUC_DEMs" \
    "dmv" \
    "Data/TerrainProcessed/HUC_TerrainMetrics/"
    
done

### Run hydro 
for number in "${include[@]}"; do
    echo "Running hydro_metrics with argument: $number"
    Rscript R_Code_Analysis/hydro_metrics_singleVect_CMD.r \
        "$GPKG" \
        "$number" \
        "Data/TerrainProcessed/HUC_DEMs/" \
        "Data/TerrainProcessed/HUC_Hydro/"
done

### Run Satellite 
for number in "${include[@]}"; do
    echo "  Cluster $number – Sentinel GEE"
        Rscript R_Code_Analysis/Sentinel_FromGEE_Processing.R \
        "Data/TerrainProcessed/HUC_DEMs/" \
        "Data/Satellite/GEE_Download_NY_HUC_Sentinel_Indices/" \
        "Data/Satellite/HUC_Processed_NY_Sentinel_Indices/" \
        "$number" 
done

### Run NAIP 
for number in "${include[@]}"; do
    echo "  Cluster $number – NAIP"
        Rscript R_Code_Analysis/NAIP_Processing_CMD.R \
        "$GPKG" \
        "$number" \
        "Data/NAIP/HUC_NAIP_Processed/"
done

### Run CHM
for number in "${include[@]}"; do
    echo "  Cluster $number – CHM"
        Rscript R_Code_Analysis/CHM_extraction.R \
        "$GPKG" \
        "$number" \
        "Data/CHMs/AWS"
done

### Run LiDAR 
for number in "${include[@]}"; do
    echo "Running Lidar_HUC_Processing with argument: $number"
      Rscript R_Code_Analysis/terrain_metrics_noparallel_filter_singleVect_CMD.r \
          "$number" \
          "Data/TerrainProcessed/HUC_DEMs" \
          "curv" \
          "Data/TerrainProcessed/HUC_TerrainMetrics/"
done