#!/bin/bash -l
#SBATCH --partition=R256C128
#SBATCH --nodelist=cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --job-name=terrain
#SBATCH --mem-per-cpu=96G
#SBATCH --ntasks=4
#SBATCH --cpus-per-task=1
#SBATCH --output=Shell_Scripts/SLURM/slurm-terrain-%j.out

# Usage: sbatch [--mem-per-cpu=X --cpus-per-task=Y] step_terrain.sh <include_csv> [metric]
#
# metric: "slp" (the only value; defaults to slp). It names the ONE combined
#   terrain raster per HUC -- cluster_<n>_huc_<id>_terrain_slp_local.tif -- whose
#   bands are slope_local, TPI_local, Geomorph_local, meanc_local, dmv_local.
#   Mean curvature and DMV used to be separate curv/dmv metrics writing separate
#   files; they were folded into this stack 2026-07, along with the removal of
#   the multiscale (5/100/500 m) smoothing. Passing curv or dmv now errors out.
#
# FORCE_TERRAIN=1 sbatch ... rebuilds every HUC. Not normally needed: the R step
#   skips a HUC only when the existing file's band names match the contract, so
#   pre-2026-07 3-band terrain rasters are rebuilt automatically.
#
# PARTITION OVERRIDE -- the #SBATCH directives below default to R256C128
#   (cbsuxu09-10, 251 GB/node). sbatch command-line flags take precedence over
#   #SBATCH directives, so the small-node partition is reached with:
#
#     sbatch --partition=R128C40 \
#            --nodelist=cbsuxu01,cbsuxu02,cbsuxu03,cbsuxu04,cbsuxu05,cbsuxu06,cbsuxu07,cbsuxu08 \
#            --ntasks=8 --mem-per-cpu=120G \
#            Shell_Scripts/step_terrain.sh <clusters> slp
#
#   or, more simply, via the master script:
#     TERRAIN_PARTITION=R128C40 bash Shell_Scripts/step_combined_master.sh <clusters> slp
#
#   A job cannot span partitions, so this is an either/or per job -- submit a
#   separate job per partition to use both node sets at once.
#
# TASK_MEM_MB -- normally derived below from the cgroup (mem-per-cpu x cpus) and
#   used by the R step to size terra's memmax (85% of it). Pre-set it to pin
#   terra lower than the allocation, which is what the small nodes need:
#   rgeomorphon and MultiscaleDTM allocate OUTSIDE terra's block accounting, so
#   real RSS runs well above memmax (measured 107 GB against an 81 GB memmax on
#   cbsuxu09). On a 125 GB node that overshoot is the difference between
#   finishing and an OOM kill, so leave terra a smaller working set and let it
#   spill to TMPDIR instead.

cd /ibstorage/anthony/NYS_Wetlands_Data/
export TMPDIR=/ibstorage/anthony/NYS_Wetlands_Data/Data/tmp/
module load R/4.4.3

IFS=',' read -ra include <<< "$1"
metric="${2:-slp}"
DATE=$(date +%Y%m%d)

# Snapshot the per-task memory budget (MB) before unsetting the SLURM mem vars,
# so the R step can size terra::memmax to the cgroup (mem-per-cpu × cpus) rather
# than node RAM. Tracks the #SBATCH directives above and survives the unset.
# An inherited TASK_MEM_MB wins, so terra can be pinned below the allocation
# (see the header) without touching the R script -- which matters because the R
# script, unlike this one, is NOT snapshotted by sbatch and is re-read from disk
# by every srun step, including those of already-queued jobs.
export TASK_MEM_MB="${TASK_MEM_MB:-$(( ${SLURM_MEM_PER_CPU:-0} * ${SLURM_CPUS_PER_TASK:-1} ))}"
unset SLURM_MEM_PER_CPU SLURM_MEM_PER_NODE SLURM_MEM_PER_GPU
echo "terra budget: TASK_MEM_MB=${TASK_MEM_MB} (memmax ~$(( TASK_MEM_MB * 85 / 100 / 1024 )) GB)"

echo "=== Terrain metric: $metric ==="
for number in "${include[@]}"; do
    echo "  Cluster $number – $metric"
    srun --nodes=1 --ntasks=1 --exclusive \
        Rscript R_Code_Analysis/terrain_metrics_filter_singleVect_CMD.R \
        "$number" \
        "Data/TerrainProcessed/HUC_DEMs" \
        "$metric" \
        "Data/TerrainProcessed/HUC_TerrainMetrics/" \
        >> "Shell_Scripts/logs/terrain_${metric}_${number}_${DATE}.log" 2>&1 &
done

wait
echo "Terrain $metric completed."
