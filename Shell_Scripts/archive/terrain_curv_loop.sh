#!/bin/bash -l
#SBATCH --nodelist=cbsuxu09,cbsuxu10
#SBATCH --batch=cbsuxu09
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem-per-cpu=128G
#SBATCH --cpus-per-task=1
#SBATCH --job-name=curv
#SBATCH --ntasks=2
#SBATCH --output=Shell_Scripts/SLURM/slurm-curv-%j.out

cd /ibstorage/anthony/NYS_Wetlands_Data/

export TMPDIR=/ibstorage/anthony/tmp

module load R/4.4.3

#Batch import
source Shell_Scripts/batch_config.sh
include=("${batch1[@]}")

# Loop through each number in the list
for number in "${include[@]}"; do
    echo "Running Rscript with argument: $number" 
    # srun --nodes=1 --ntasks=1 --exclusive \
    Rscript R_Code_Analysis/terrain_metrics_noparallel_filter_singleVect_CMD.R \
    "$number" \
    "Data/TerrainProcessed/HUC_DEMs" \
    "curv" \
    "Data/TerrainProcessed/HUC_TerrainMetrics/" >> "Shell_Scripts/logs/terrain_curv_"$number"_$(date +%Y%m%d).log" 2>&1 &
    
done

wait

echo "All Rscript executions completed."

