#!/bin/bash -l

module load R/4.4.3
cd /ibstorage/anthony/NYS_Wetlands_Data/

include=(11 225)

# # Run hydro metrics sequentially
# for number in "${include[@]}"; do
#     echo "Running hydro_metrics with argument: $number"
#     Rscript R_Code_Analysis/hydro_metrics_singleVect_CMD.r \
#         "Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg" \
#         "$number" \
#         "Data/TerrainProcessed/HUC_DEMs/" \
#         "Data/TerrainProcessed/HUC_Hydro/"
# done
# 
# Run LiDAR processing sequentially
for number in "${include[@]}"; do
    echo "Running Lidar_HUC_Processing with argument: $number"
    Rscript R_Code_Analysis/Lidar_HUC_Processing.R \
        "Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg" \
        "$number" \
        "Data/Lidar/HUC_Lidar_Metrics/"
done

# Run LiDAR processing sequentially
# for number in "${include[@]}"; do
#     echo "Running Lidar_HUC_Processing with argument: $number"
#       Rscript R_Code_Analysis/terrain_metrics_noparallel_filter_singleVect_CMD.r \
#           "$number" \
#           "Data/TerrainProcessed/HUC_DEMs" \
#           "curv" \
#           "Data/TerrainProcessed/HUC_TerrainMetrics/"
# done