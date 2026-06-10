#!/bin/bash -l
#SBATCH --nodelist=cbsuxu07,cbsuxu08,cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem-per-cpu=24G
#SBATCH --cpus-per-task=4
#SBATCH --job-name=stats
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --output=Shell_Scripts/SLURM/slurm-stats-%j.out


cd /ibstorage/anthony/NYS_Wetlands_Data/

export TMPDIR=/ibstorage/anthony/tmp

module load R/4.4.3

# Per-cluster partial stats, merged into one global JSON afterwards.
PARTIALS="Data/HUC_Raster_Stacks/Stats_Partials"
GLOBAL_JSON="Data/HUC_Raster_Stacks/HUC_DL_Stacks_Extracted_Values.json"
mkdir -p "$PARTIALS"

source Shell_Scripts/batch_config.sh
include=("${batch1[@]}")

# 1. Map: per-cluster min/max over all HUCs in the cluster (in-memory stacks)
for number in "${include[@]}"; do
    echo "Computing band stats for cluster: $number"
    srun --nodes=1 --ntasks=1 --exclusive \
        Rscript R_Code_Analysis/DL_Extract_Normalize_Stats_FullRasters.R \
        "$number" \
        "${PARTIALS}/cluster_${number}.json" >> "Shell_Scripts/logs/stats_${number}_$(date +%Y%m%d).log" 2>&1 &
done

wait
echo "All per-cluster stats completed."

# 2. Reduce: merge every partial present into the global JSON (min-of-mins /
#    max-of-maxs). Run after ALL batches' partials exist for the true global.
echo "Merging partials into ${GLOBAL_JSON}"
Rscript R_Code_Analysis/merge_band_stats.R "$PARTIALS" "$GLOBAL_JSON" \
    >> "Shell_Scripts/logs/stats_merge_$(date +%Y%m%d).log" 2>&1

echo "Stats pipeline complete."
