#!/bin/bash -l

cd /ibstorage/anthony/NYS_Wetlands_Data/

export TMPDIR=/ibstorage/anthony/tmp

module load R/4.4.3

Rscript R_Code_Analysis/DL_CropSmooth_Predictions.R \
"Data/HUC_DL_Predictions/" \
"TRUE" \
"Data/HUC_DL_Predictions/HUC_DL_Predictions_Clean/" >> "Shell_Scripts/logs/clean_$(date +%Y%m%d).log" 2>&1 &


echo "All Rscript executions completed."
q