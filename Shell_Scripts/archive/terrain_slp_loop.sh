#!/bin/bash -l
#SBATCH --nodelist=cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem-per-cpu=64G
#SBATCH --cpus-per-task=2
#SBATCH --job-name=slp
#SBATCH --ntasks=2
#SBATCH --output=Shell_Scripts/SLURM/slurm-slp-%j.out


cd /ibstorage/anthony/NYS_Wetlands_Data/

export TMPDIR=/ibstorage/anthony/tmp

module load R/4.4.3

#Batch import
source Shell_Scripts/batch_config.sh
include=("${batch1[@]}")

# Loop through each number in the list
for number in "${include[@]}"; do
    echo "Running Rscript with argument: $number"
    Rscript R_Code_Analysis/terrain_metrics_filter_singleVect_CMD.R \
    "$number" \
    "Data/TerrainProcessed/HUC_DEMs" \
    "slp" \
    "Data/TerrainProcessed/HUC_TerrainMetrics/" >> "Shell_Scripts/logs/terrain_slp_$(date +%Y%m%d).log" 2>&1
    
done

echo "All Rscript executions completed."

