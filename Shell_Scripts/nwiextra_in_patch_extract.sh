#!/bin/bash -l

cd /ibstorage/anthony/NYS_Wetlands_Data

export TMPDIR=/ibstorage/anthony/tmp

module load R/4.4.3

Rscript R_Code_Analysis/NWI_Extract_From_Patches.R \
    "Data/NWI/NY_NWI_6347.gpkg" \
    "Data/Training_Data/R_Patches_Vector_NWIextra/" \
    "Data/Training_Data/R_Patches_Vector_Reviewed/" \
    "Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg" >> "Shell_Scripts/logs/nwiextra_patch_${number}_$(date +%Y%m%d).log" 2>&1 &

wait
echo "All Rscript executions completed."