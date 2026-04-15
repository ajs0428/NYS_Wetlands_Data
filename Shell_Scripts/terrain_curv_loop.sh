#!/bin/bash -l
#SBATCH --nodelist=cbsuxu09,cbsuxu10
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


# Define the list of numbers
# include=(11 12 22 51 53 56 60 64 67 84 86 90 92 102 105 116 120 123 136 138 152 176 183 189 192 193 198 208 218 225 250)
include=(11 22 46 50 64 67 82 95 123 168 208 218 225 250)
# Loop through each number in the list
for number in "${include[@]}"; do
    echo "Running Rscript with argument: $number" 
    srun --nodes=1 --ntasks=1 --exclusive \
    Rscript R_Code_Analysis/terrain_metrics_noparallel_filter_singleVect_CMD.r \
    "$number" \
    "Data/TerrainProcessed/HUC_DEMs" \
    "curv" \
    "Data/TerrainProcessed/HUC_TerrainMetrics/" >> "Shell_Scripts/logs/terrain_curv_"$number"_$(date +%Y%m%d).log" 2>&1 &
    
done

wait

echo "All Rscript executions completed."

