#!/bin/bash -l
#SBATCH --partition=R256C128
#SBATCH --nodelist=cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem-per-cpu=48G
#SBATCH --cpus-per-task=2
#SBATCH --job-name=lidar_ftp
#SBATCH --ntasks=4
#SBATCH --time=24:00:00
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
# =============================================================================

cd /ibstorage/anthony/NYS_Wetlands_Data/
export TMPDIR=/ibstorage/anthony/NYS_Wetlands_Data/Data/tmp/
module load R/4.4.3

source Shell_Scripts/batch_config.sh   # GPKG, LIDAR_INDEX

IFS=',' read -ra include <<< "$1"
OUTDIR="Data/Lidar/Metrics"
DATE=$(date +%Y%m%d)

unset SLURM_MEM_PER_CPU SLURM_MEM_PER_NODE SLURM_MEM_PER_GPU

echo "=== Lidar tile download + metrics (combined index) ==="
for number in "${include[@]}"; do
    echo "  Cluster $number – lidar FTP"
    srun --nodes=1 --ntasks=1 --exclusive \
        Rscript R_Code_Analysis/LIDAR_ftp.R \
        "$GPKG" \
        "$number" \
        "$LIDAR_INDEX" \
        "$OUTDIR" \
        >> "Shell_Scripts/logs/lidar_ftp_${number}_${DATE}.log" 2>&1 &
done

wait
echo "Lidar tile download + metrics completed."
