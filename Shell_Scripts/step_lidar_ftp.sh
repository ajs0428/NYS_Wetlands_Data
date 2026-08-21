#!/bin/bash -l
#SBATCH --partition=R256C128
#SBATCH --nodelist=cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem-per-cpu=16G
#SBATCH --cpus-per-task=2
#SBATCH --job-name=lidar_ftp
#SBATCH --ntasks=12
#SBATCH --time=36:00:00
#SBATCH --output=Shell_Scripts/SLURM/slurm-lidar-ftp-%j.out

# =============================================================================
# LIDAR TILE DOWNLOAD + METRICS -- one task per cluster.
#
#   Usage:  sbatch step_lidar_ftp.sh "<comma-sep clusters>"
#
# LIDAR_ftp.R selects every tile from the COMBINED index
# (Data/Lidar/NYS_Lidar_All_Indexes.gpkg) that overlaps the cluster's HUC12s,
# downloads each LAS over FTP, computes the vegetation metrics, and writes
# 1 m tiles to Data/Lidar/Metrics/. Already-processed tiles are skipped, so
# re-runs are cheap. This replaces the hand-maintained cluster|index table
# that lived in lidar_loop.sh.
#
# PREREQUISITE (once per data refresh): the combined index must include any
# newly published collections. Refresh with:
#   Rscript R_Code_Analysis/download_lidar_indexes.R
#   Rscript R_Code_Analysis/build_lidar_index.R
#
# To re-run a single collection for a cluster, call LIDAR_ftp.R directly with
# that collection's index gpkg from Data/Lidar/Indexes/ as the 3rd argument.
#
# SIZING: --ntasks is the concurrency budget and the loop below launches one
# srun step per cluster, so anything beyond --ntasks queues -- with ntasks=4 and
# a 14-cluster batch, 10 clusters spent all 24h logging "step creation still
# disabled" and the job died on the wall clock (786256, 2026-08-18). Measured
# peak RSS of a step is ~24 GB (sacct MaxRSS over job 786256), so the old
# 48G x 2cpu = 96 GB/task was 4x over-provisioned; 16G x 2cpu = 32 GB/task
# holds the same 384 GB job footprint while tripling concurrency. Raising
# ntasks further starves the terrain/naip/ortho stages, which want 320-384 GB
# themselves and cannot co-schedule on only two ~251 GB nodes.
#
# HANG DETECTION: this stage has a history of sitting alive after all tiles are
# finished. LIDAR_ftp.R bumps a per-cluster heartbeat file on every tile, and
# the watchdog below kills a step that either (a) printed its completion banner
# and did not exit, or (b) made no tile progress for LIDAR_STALL_MIN minutes.
# Rasters already on disk are skipped on the next run, so a kill costs nothing.
# =============================================================================

cd /ibstorage/anthony/NYS_Wetlands_Data/
export TMPDIR=/ibstorage/anthony/NYS_Wetlands_Data/Data/tmp/
module load R/4.4.3

source Shell_Scripts/batch_config.sh   # GPKG, LIDAR_INDEX

IFS=',' read -ra include <<< "$1"
OUTDIR="Data/Lidar/Metrics"
DATE=$(date +%Y%m%d)
HBDIR="Shell_Scripts/logs/heartbeats"
mkdir -p "$HBDIR"

# Watchdog thresholds (minutes). A tile takes ~2-3 min, so 90 min of silence is
# a hang, not a slow tile. DONE_GRACE covers the post-completion hang.
LIDAR_STALL_MIN=${LIDAR_STALL_MIN:-90}
LIDAR_DONE_GRACE_MIN=${LIDAR_DONE_GRACE_MIN:-10}

unset SLURM_MEM_PER_CPU SLURM_MEM_PER_NODE SLURM_MEM_PER_GPU

# Kill an srun step that has stopped making progress. Polls once a minute and
# returns as soon as the step exits on its own.
watchdog() {
    local cl="$1" pid="$2" hb="$3" log="$4"
    local stall_s=$(( LIDAR_STALL_MIN * 60 ))
    local grace_s=$(( LIDAR_DONE_GRACE_MIN * 60 ))
    local done_at=0 now last

    while kill -0 "$pid" 2>/dev/null; do
        sleep 60
        kill -0 "$pid" 2>/dev/null || return 0
        now=$(date +%s)

        # (a) R printed its completion banner but the step is still alive.
        #     Everything is already written, so this is the known shutdown hang.
        if grep -aq '=== Done\.' "$log" 2>/dev/null; then
            [[ $done_at -eq 0 ]] && done_at=$now
            if (( now - done_at > grace_s )); then
                echo "  WATCHDOG cluster $cl: completed but still alive after ${LIDAR_DONE_GRACE_MIN}m - terminating" >&2
                kill -TERM "$pid" 2>/dev/null; sleep 30; kill -KILL "$pid" 2>/dev/null
                return 0
            fi
            continue
        fi

        # (b) No tile has started or finished in LIDAR_STALL_MIN minutes.
        #     Absent heartbeat means the step is still queued or still reading
        #     the index -- not yet in the tile loop, so nothing to judge.
        [[ -f "$hb" ]] || continue
        last=$(stat -c %Y "$hb" 2>/dev/null) || continue
        if (( now - last > stall_s )); then
            echo "  WATCHDOG cluster $cl: no tile progress for ${LIDAR_STALL_MIN}m - terminating" >&2
            kill -TERM "$pid" 2>/dev/null; sleep 30; kill -KILL "$pid" 2>/dev/null
            return 0
        fi
    done
}

echo "=== Lidar tile download + metrics (combined index) ==="
echo "  Concurrency: $SLURM_NTASKS tasks x $SLURM_CPUS_PER_TASK cpus | clusters: ${#include[@]}"
echo "  Watchdog: stall ${LIDAR_STALL_MIN}m, post-completion grace ${LIDAR_DONE_GRACE_MIN}m"

srun_pids=()
wd_pids=()
for number in "${include[@]}"; do
    echo "  Cluster $number – lidar FTP"
    log="Shell_Scripts/logs/lidar_ftp_${number}_${DATE}.log"
    hb="$HBDIR/lidar_ftp_${number}.hb"
    rm -f "$hb"
    srun --nodes=1 --ntasks=1 --exclusive \
        Rscript R_Code_Analysis/LIDAR_ftp.R \
        "$GPKG" \
        "$number" \
        "$LIDAR_INDEX" \
        "$OUTDIR" \
        "$hb" \
        >> "$log" 2>&1 &
    srun_pid=$!
    srun_pids+=("$srun_pid")
    watchdog "$number" "$srun_pid" "$hb" "$log" &
    wd_pids+=("$!")
done

# Wait only on the work; the watchdogs exit by themselves once their step does.
for p in "${srun_pids[@]}"; do wait "$p"; done
for p in "${wd_pids[@]}"; do kill "$p" 2>/dev/null; done
wait 2>/dev/null

rm -f "$HBDIR"/lidar_ftp_*.hb
echo "Lidar tile download + metrics completed."

# Surface any per-cluster failure lists this run produced.
for number in "${include[@]}"; do
    ff="Shell_Scripts/logs/lidar_ftp_${number}_failed_tiles.txt"
    [[ -s "$ff" ]] && echo "  Cluster $number: $(wc -l < "$ff") tiles with no output -> $ff"
done
exit 0
