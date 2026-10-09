#!/bin/bash -l
#SBATCH --partition=R256C128
#SBATCH --nodelist=cbsuxu09,cbsuxu10
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
#           Default: batch1 .. batch18 -- every cluster, i.e. the full
#           prediction domain.
#
# Stack profile (see stack_profiles() in huc_stack.R) comes from the
# HUC_STACK_PROFILE env var, default "prod":
#   prod      -> NYS_Wetlands_Prod. 5 sources (no ortho/lidar), so HUCs lacking
#                leaf-off ortho or lidar still count. Writes
#                HUC_DL_Stacks_Extracted_Values_prod.json via Stats_Partials_prod/.
#   factorial -> the frozen NYS_Wetlands_DL (factorial-v3) recipe. Writes the
#                original HUC_DL_Stacks_Extracted_Values.json via Stats_Partials/.
# Each profile has its own partials dir + JSON, so one never clobbers the other.
#
# RESUME=1 keeps existing partials and only recomputes clusters that have no
# partial yet (e.g. after OOM kills), then re-merges everything. Pass the same
# batches as the original run.
#
# Examples:
#   sbatch Shell_Scripts/dl_extract_normalize_stats.sh                  # prod, all batches
#   sbatch Shell_Scripts/dl_extract_normalize_stats.sh batch1           # prod, batch1 only
#   RESUME=1 sbatch Shell_Scripts/dl_extract_normalize_stats.sh        # fill in failed clusters
#   HUC_STACK_PROFILE=factorial sbatch Shell_Scripts/dl_extract_normalize_stats.sh batch1 batch2 batch3
#
# IMPORTANT: the run CLEARS the profile's partials dir (cluster_*.json) first, so the merged
# global JSON reflects ONLY the batches passed to this invocation. To widen
# coverage, pass every batch you want in one call -- running batch3 alone after
# a batch1+batch2 run throws the earlier clusters away. Batches cannot be split
# across concurrent jobs for the same reason (they would clear each other's
# partials).
#
# Concurrency: --ntasks=4 with `srun --exclusive` runs 4 clusters at a time
# (4 CPUs x 24 GB = 96 GB each, 2 per R256C128 node); the remaining clusters
# queue behind them, and `wait` holds the merge until every cluster finishes.
# srun gets --cpus-per-task explicitly: since Slurm 22.05 it no longer inherits
# it from sbatch, so each step got 1 CPU / 24 GB while R still started
# SLURM_CPUS_PER_TASK=4 callr workers -> OOM kills.
#
# Prerequisites: every HUC in the requested clusters needs its full stack
# sources on disk (DEM/terrain/hydro/CHM/NAIP/ortho) -- check with
# `bash Shell_Scripts/check_stack_ready.sh`. Re-run this whenever the band
# recipe in R_Code_Analysis/huc_stack.R changes, since the PyTorch model
# normalizes against the JSON band-by-band.
#
# Logs: Shell_Scripts/logs/stats_<profile>_<cluster>_<YYYYMMDD>.log per cluster,
#       Shell_Scripts/logs/stats_<profile>_merge_<YYYYMMDD>.log for the merge,
#       Shell_Scripts/SLURM/slurm-stats-<jobid>.out for the driver.
# =============================================================================


cd /ibstorage/anthony/NYS_Wetlands_Data/

export TMPDIR=/ibstorage/anthony/tmp

module load R/4.4.3

# Stack profile -- exported so the Rscript (and its callr workers) build the
# same source set via stack_profile() in huc_stack.R.
export HUC_STACK_PROFILE="${HUC_STACK_PROFILE:-prod}"
case "$HUC_STACK_PROFILE" in
    prod)      SUFFIX="_prod" ;;
    factorial) SUFFIX="" ;;      # original paths, used by NYS_Wetlands_DL
    *) echo "ERROR: unknown HUC_STACK_PROFILE '$HUC_STACK_PROFILE'" >&2; exit 1 ;;
esac

# Per-cluster partial stats, merged into one global JSON afterwards.
PARTIALS="Data/HUC_Raster_Stacks/Stats_Partials${SUFFIX}"
GLOBAL_JSON="Data/HUC_Raster_Stacks/HUC_DL_Stacks_Extracted_Values${SUFFIX}.json"
mkdir -p "$PARTIALS"

source Shell_Scripts/batch_config.sh

# Batches whose clusters get stats computed (see the usage block above).
batches=("$@")
if [ ${#batches[@]} -eq 0 ]; then
    batches=(batch{1..18})
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

echo "Profile: ${HUC_STACK_PROFILE} -> ${GLOBAL_JSON}"
echo "Computing stats over batches: ${batches[*]} (${#include[@]} clusters)"

# Clear stale partials so the merge reflects ONLY this run's batches. Partials
# persist across runs, so without this a prior larger run's clusters would still
# fold into the global JSON. RESUME=1 keeps them and skips finished clusters.
if [ "${RESUME:-0}" = "1" ]; then
    echo "RESUME=1: keeping partials in ${PARTIALS}; skipping clusters that have one"
else
    echo "Clearing stale partials in ${PARTIALS}"
    rm -f "${PARTIALS}"/cluster_*.json
fi

# 1. Map: per-cluster min/max over all HUCs in the cluster (in-memory stacks)
for number in "${include[@]}"; do
    if [ "${RESUME:-0}" = "1" ] && [ -s "${PARTIALS}/cluster_${number}.json" ]; then
        continue
    fi
    echo "Computing band stats for cluster: $number"
    srun --nodes=1 --ntasks=1 --cpus-per-task="${SLURM_CPUS_PER_TASK}" --exclusive \
        Rscript R_Code_Analysis/DL_Extract_Normalize_Stats_FullRasters.R \
        "$number" \
        "${PARTIALS}/cluster_${number}.json" >> "Shell_Scripts/logs/stats_${HUC_STACK_PROFILE}_${number}_$(date +%Y%m%d).log" 2>&1 &
done

wait
echo "All per-cluster stats completed."

# 2. Reduce: merge this run's partials into the global JSON (min-of-mins /
#    max-of-maxs). The partials dir was cleared above, so it holds only the
#    batches passed to this run -- the merge reflects exactly those batches.
echo "Merging partials into ${GLOBAL_JSON}"
Rscript R_Code_Analysis/merge_band_stats.R "$PARTIALS" "$GLOBAL_JSON" \
    >> "Shell_Scripts/logs/stats_${HUC_STACK_PROFILE}_merge_$(date +%Y%m%d).log" 2>&1

echo "Stats pipeline complete."
