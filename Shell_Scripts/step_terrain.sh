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

# CONCURRENCY -- must not exceed the job's task budget, and there is no second
# place to keep in sync: it tracks whatever --ntasks the job was submitted with
# (4 on R256C128, 8 on the R128C40 override in step_combined_master.sh).
#
# Why the throttle below exists. sbatch JOBS queue durably; srun STEPS do not.
# An srun that finds no free task slot is not queued -- it spins in a
# client-side retry loop ("Requested nodes are busy") and eventually gives up:
#
#   srun: error: Unable to create step for job 786483: Step limit reached for this job
#
# The loop used to fire one backgrounded srun per cluster with no throttle, so
# all of them launched at once against 4 slots. The surplus spun for ~27.5 h and
# were then all rejected within three minutes of each other -- the R step never
# started and those clusters were silently skipped. Job 786388 (2026-09-03) lost
# 54 of 74 clusters this way; job 786483 (2026-09-09) lost 34 of 74. The 27
# clusters that starved in BOTH runs were exactly the 27 still missing terrain.
# Holding the line at NPAR outstanding sruns means each one is launched into a
# slot that is already free, instead of into a 27-hour waiting room. Throughput
# is unchanged (concurrency was already NPAR); nothing evaporates.
NPAR="${TERRAIN_CONCURRENCY:-${SLURM_NTASKS:-4}}"

declare -A running=()   # pid -> cluster number
failed=()

# Block until one srun finishes, then record it. wait -n -p needs bash >= 5.1.
reap_one() {
    local pid rc c
    wait -n -p pid; rc=$?
    if [[ -z "$pid" ]]; then
        # wait -n returned without naming a child (signal, or nothing left).
        # Harvest everything and reset rather than spin forever. Per-cluster
        # status is lost on this path, but the check stage still catches gaps.
        wait
        running=()
        return 0
    fi
    c="${running[$pid]}"
    unset 'running[$pid]'
    if (( rc != 0 )); then
        failed+=("$c(rc=$rc)")
        echo "  Cluster $c FAILED (rc=$rc)" >&2
    fi
}

echo "=== Terrain metric: $metric (concurrency $NPAR) ==="
for number in "${include[@]}"; do
    while (( ${#running[@]} >= NPAR )); do reap_one; done

    echo "  Cluster $number – $metric"
    # Slurm 22.05: srun no longer inherits --cpus-per-task from sbatch.
    srun --nodes=1 --ntasks=1 --cpus-per-task="${SLURM_CPUS_PER_TASK:-1}" --exclusive \
        Rscript R_Code_Analysis/terrain_metrics_filter_singleVect_CMD.R \
        "$number" \
        "Data/TerrainProcessed/HUC_DEMs" \
        "$metric" \
        "Data/TerrainProcessed/HUC_TerrainMetrics/" \
        >> "Shell_Scripts/logs/terrain_${metric}_${number}_${DATE}.log" 2>&1 &
    running[$!]=$number
done

while (( ${#running[@]} > 0 )); do reap_one; done

# Exit non-zero so a lost cluster surfaces as mail + a red sacct line instead of
# a silent COMPLETED. Safe: terrain is a LEAF in step_combined_master.sh --
# hydro/chm/naip hang off jid_dem, not off jid_slp, and the check job depends on
# it with afterany. A failure here cancels nothing downstream.
if (( ${#failed[@]} > 0 )); then
    echo "Terrain $metric FAILED for ${#failed[@]} cluster(s): ${failed[*]}" >&2
    exit 1
fi
echo "Terrain $metric completed."
