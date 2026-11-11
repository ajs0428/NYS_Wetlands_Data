#!/bin/bash -l
#SBATCH --partition=R256C128
#SBATCH --nodes=1   # NOT --nodelist=09,10: that forces EVERY array element onto both nodes
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=END,FAIL
#SBATCH --mem=40G
# WhiteboxTools needs >= 2 CPUs: several tools hit a thread race in a 1-CPU cgroup.
#SBATCH --cpus-per-task=2
#SBATCH --array=1-12
#SBATCH --job-name=hand
#SBATCH --output=Shell_Scripts/SLURM/slurm-hand-%A_%a.out

# =============================================================================
# Height Above Nearest Drainage (HAND) per HUC12 (R_Code_Analysis/hydro_HAND.R).
# Needs the hydro stage's outputs: HUC_DEM_Hydro/*_wbt.tif + HUC_Hydro/*_TWI_Facc.tif
#
#   sbatch Shell_Scripts/step_hand.sh                # all clusters
#   sbatch Shell_Scripts/step_hand.sh 12,64          # comma list of clusters
#   sbatch Shell_Scripts/step_hand.sh batch2         # a batch from batch_config.sh
#   sbatch --array=1-2 Shell_Scripts/step_hand.sh 118    # small run, fewer elements
#   THRESHOLD=250000 sbatch Shell_Scripts/step_hand.sh   # stream threshold (flowacc cells)
#
# A job array, not srun steps inside one job: each element gets its own fixed
# memory. The HUC list is sorted largest-first and dealt round-robin across
# SLURM_ARRAY_TASK_COUNT elements, so the elements finish at about the same time.
# Memory: WBT ElevationAboveStream peaks at ~32 bytes/cell (15 GB RSS for a
# 460M-cell HUC, 4.6 min; the largest HUC with flowacc is 895M cells -> ~29 GB),
# hence 40G: 6 elements per node, 12 at once.
# Resumable: HUCs whose HAND raster exists are skipped, so just resubmit.
# Per-element R logs: Shell_Scripts/logs/hand_<jobid>_<element>.log
# =============================================================================

cd /ibstorage/anthony/NYS_Wetlands_Data/
export TMPDIR=/ibstorage/anthony/NYS_Wetlands_Data/Data/tmp/
module load R/4.4.3
source Shell_Scripts/batch_config.sh   # batchN arrays

# $1: "all" (default), a comma list of clusters, or a batch name
CLUSTERS=${1:-all}
if [[ "$CLUSTERS" =~ ^batch[0-9]+$ ]]; then
    declare -n _batch="$CLUSTERS"
    if [[ ${#_batch[@]} -eq 0 ]]; then
        echo "Unknown batch: $CLUSTERS" >&2
        exit 1
    fi
    CLUSTERS=$(IFS=,; echo "${_batch[*]}")
fi
THRESHOLD=${THRESHOLD:-500000}

# Per-task memory budget (MB) for the R step, then drop the SLURM mem vars
# (same convention as the other step scripts).
export TASK_MEM_MB=$(( 40 * 1024 ))
unset SLURM_MEM_PER_CPU SLURM_MEM_PER_NODE SLURM_MEM_PER_GPU

LOG="Shell_Scripts/logs/hand_${SLURM_ARRAY_JOB_ID:-manual}_${SLURM_ARRAY_TASK_ID:-1}.log"
echo "HAND: clusters=$CLUSTERS threshold=$THRESHOLD slice ${SLURM_ARRAY_TASK_ID:-1}/${SLURM_ARRAY_TASK_COUNT:-1} -> $LOG"

Rscript R_Code_Analysis/hydro_HAND.R \
    "$CLUSTERS" \
    "Data/TerrainProcessed/HUC_DEM_Hydro/" \
    "Data/TerrainProcessed/HUC_Hydro/" \
    "Data/TerrainProcessed/HUC_HAND/" \
    "Data/TerrainProcessed/HUC_Streams/" \
    "$THRESHOLD" \
    "${SLURM_ARRAY_TASK_ID:-1}" \
    "${SLURM_ARRAY_TASK_COUNT:-1}" \
    > "$LOG" 2>&1
rc=$?

if [[ $rc -ne 0 ]]; then
    echo "HAND slice ${SLURM_ARRAY_TASK_ID:-1} finished with failures (see $LOG)"
    exit $rc
fi
echo "HAND slice ${SLURM_ARRAY_TASK_ID:-1} completed."
