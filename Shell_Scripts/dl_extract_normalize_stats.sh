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

# =============================================================================
# Global min/max band statistics for the DL normalization pipeline.
#
# Two phases in one job:
#   1. Map    -- one Rscript DL_Extract_Normalize_Stats_FullRasters.R per
#                cluster, writing Stats_Partials/cluster_<N>.json. Stacks are
#                assembled in memory per HUC via huc_stack.R, so the stats
#                always match the bands the chip/point pipelines produce.
#                Population is ALL HUCs in the cluster polygon, not just HUCs
#                that have training patches, so the ranges cover the full
#                prediction domain.
#   2. Reduce -- merge_band_stats.R folds this run's partials into
#                Data/HUC_Raster_Stacks/HUC_DL_Stacks_Extracted_Values.json
#                (min-of-mins / max-of-maxs per band).
#
# Usage:
#   sbatch Shell_Scripts/dl_extract_normalize_stats.sh [BATCH ...]
#
#   BATCH   one or more batch names defined in batch_config.sh (batch1 ..
#           batch18). Bare cluster numbers are NOT accepted -- only names.
#           An unknown name aborts before any work. Clusters appearing in more
#           than one batch are de-duplicated so each is computed once.
#           Default: batch1 batch2 batch3 -- the sets the model trains on.
#
# Examples:
#   sbatch Shell_Scripts/dl_extract_normalize_stats.sh                  # batch1+2+3
#   sbatch Shell_Scripts/dl_extract_normalize_stats.sh batch1           # batch1 only
#   sbatch Shell_Scripts/dl_extract_normalize_stats.sh batch1 batch2 batch3 batch4
#
# IMPORTANT: the run CLEARS Stats_Partials/cluster_*.json first, so the merged
# global JSON reflects ONLY the batches passed to this invocation. To widen
# coverage, pass every batch you want in one call -- running batch3 alone after
# a batch1+batch2 run throws the earlier clusters away. Batches cannot be split
# across concurrent jobs for the same reason (they would clear each other's
# partials).
#
# Concurrency: --ntasks=4 with `srun --exclusive` runs 4 clusters at a time
# (4 CPUs x 24 GB each); the remaining clusters queue behind them, and `wait`
# holds the merge until every cluster finishes.
#
# Prerequisites: every HUC in the requested clusters needs its full stack
# sources on disk (DEM/terrain/hydro/CHM/NAIP/ortho) -- check with
# `bash Shell_Scripts/check_stack_ready.sh`. Re-run this whenever the band
# recipe in R_Code_Analysis/huc_stack.R changes, since the PyTorch model
# normalizes against the JSON band-by-band.
#
# Logs: Shell_Scripts/logs/stats_<cluster>_<YYYYMMDD>.log per cluster,
#       Shell_Scripts/logs/stats_merge_<YYYYMMDD>.log for the merge,
#       Shell_Scripts/SLURM/slurm-stats-<jobid>.out for the driver.
# =============================================================================


cd /ibstorage/anthony/NYS_Wetlands_Data/

export TMPDIR=/ibstorage/anthony/tmp

module load R/4.4.3

# Per-cluster partial stats, merged into one global JSON afterwards.
PARTIALS="Data/HUC_Raster_Stacks/Stats_Partials"
GLOBAL_JSON="Data/HUC_Raster_Stacks/HUC_DL_Stacks_Extracted_Values.json"
mkdir -p "$PARTIALS"

source Shell_Scripts/batch_config.sh

# Batches whose clusters get stats computed (see the usage block above).
batches=("$@")
if [ ${#batches[@]} -eq 0 ]; then
    batches=(batch1 batch2 batch3)
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
