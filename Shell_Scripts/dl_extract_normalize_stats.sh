#!/bin/bash -l
#SBATCH --partition=R128C40
#SBATCH --nodelist=cbsuxu05,cbsuxu06,cbsuxu07,cbsuxu08 
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem-per-cpu=24G
#SBATCH --cpus-per-task=4
#SBATCH --job-name=stats
#SBATCH --ntasks=4
#SBATCH --output=Shell_Scripts/SLURM/slurm-stats-%j.out


cd /ibstorage/anthony/NYS_Wetlands_Data/

export TMPDIR=/ibstorage/anthony/tmp

module load R/4.4.3

# Per-cluster partial stats, merged into one global JSON afterwards.
PARTIALS="Data/HUC_Raster_Stacks/Stats_Partials"
GLOBAL_JSON="Data/HUC_Raster_Stacks/HUC_DL_Stacks_Extracted_Values.json"
mkdir -p "$PARTIALS"

source Shell_Scripts/batch_config.sh

# Batches whose clusters get stats computed. Pass batch names as args
# (e.g. `sbatch dl_extract_normalize_stats.sh batch1 batch2 batch3`);
# defaults to batch1 + batch2, the sets the model currently trains on.
# Clusters appearing in more than one batch are de-duplicated so each is
# computed once.
batches=("$@")
if [ ${#batches[@]} -eq 0 ]; then
    batches=(batch1 batch2)
fi

include=()
declare -A seen
for b in "${batches[@]}"; do
    declare -n arr="$b"
    if [ -z "${arr+x}" ]; then
        echo "ERROR: unknown batch '$b' (not defined in batch_config.sh)" >&2
        exit 1
    fi
    for number in "${arr[@]}"; do
        if [ -z "${seen[$number]:-}" ]; then
            seen[$number]=1
            include+=("$number")
        fi
    done
    unset -n arr
done

echo "Computing stats over batches: ${batches[*]} (${#include[@]} clusters)"

# Clear stale partials so the merge reflects ONLY this run's batches. Partials
# persist across runs, so without this a prior larger run's clusters would still
# fold into the global JSON.
echo "Clearing stale partials in ${PARTIALS}"
rm -f "${PARTIALS}"/cluster_*.json

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

# 2. Reduce: merge this run's partials into the global JSON (min-of-mins /
#    max-of-maxs). The partials dir was cleared above, so it holds only the
#    batches passed to this run -- the merge reflects exactly those batches.
echo "Merging partials into ${GLOBAL_JSON}"
Rscript R_Code_Analysis/merge_band_stats.R "$PARTIALS" "$GLOBAL_JSON" \
    >> "Shell_Scripts/logs/stats_merge_$(date +%Y%m%d).log" 2>&1

echo "Stats pipeline complete."
