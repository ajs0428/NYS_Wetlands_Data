#!/bin/bash -l
#SBATCH --nodelist=cbsuxu06,cbsuxu07,cbsuxu08,cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --job-name=terrain
#SBATCH --ntasks=5
#SBATCH --ntasks-per-node=1
#SBATCH --output=Shell_Scripts/SLURM/slurm-terrain-%j.out

# Usage: sbatch [--mem-per-cpu=X --cpus-per-task=Y] step_terrain.sh <include_csv> <metric>
# metric: slp, curv, or dmv

cd /ibstorage/anthony/NYS_Wetlands_Data/
export TMPDIR=/ibstorage/anthony/NYS_Wetlands_Data/Data/tmp/
module load R/4.4.3

IFS=',' read -ra include <<< "$1"
metric="$2"
DATE=$(date +%Y%m%d)

echo "=== Terrain metric: $metric ==="
for number in "${include[@]}"; do
    echo "  Cluster $number – $metric"
    srun --nodes=1 --ntasks=1 --exclusive \
        Rscript R_Code_Analysis/terrain_metrics_filter_singleVect_CMD.r \
        "$number" \
        "Data/TerrainProcessed/HUC_DEMs" \
        "$metric" \
        "Data/TerrainProcessed/HUC_TerrainMetrics/" \
        >> "Shell_Scripts/logs/terrain_${metric}_${number}_${DATE}.log" 2>&1 &
done

wait
echo "Terrain $metric completed."
