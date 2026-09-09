#!/bin/bash -l
#SBATCH --partition=R256C128
#SBATCH --nodelist=cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
# 48G, down from 96G. 96G was sized around an OOM whose real cause was the
# in-memory list of projected tiles in NAIP_Processing_CMD.R, not any single
# raster; those tiles are file-backed now, so terra's memmax (= mem-per-cpu x
# cpus x 0.60) is once again a real bound on peak RSS. Measured after that fix:
# 20.23G for cluster 154 huc 041300030203 (256M cells, job 786473) and 28.05G
# for cluster 140 huc 042900010407 (2.27e9 cells, the largest HUC in the whole
# set, job 786474). 48G leaves ~20G over that worst case.
#SBATCH --mem-per-cpu=48G
#SBATCH --job-name=naip
# 10 = tasks-per-node x 2 nodes, where tasks-per-node =
# floor(RealMemory / mem-per-cpu) = floor(257059M / 49152M) = 5.
# Over-asking is not a soft failure: sbatch rejects the whole job with
# "Requested node configuration is not available". Re-derive this whenever
# --mem-per-cpu changes (scontrol show node cbsuxu09 | grep RealMemory).
#SBATCH --ntasks=10
#SBATCH --cpus-per-task=1
#SBATCH --output=Shell_Scripts/SLURM/slurm-naip-%j.out

cd /ibstorage/anthony/NYS_Wetlands_Data/
export TMPDIR=/ibstorage/anthony/NYS_Wetlands_Data/Data/tmp/
module load R/4.4.3

IFS=',' read -ra include <<< "$1"
GPKG="Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg"
DATE=$(date +%Y%m%d)

# Snapshot the per-task memory budget (MB) so the R step can size terra::memmax
# to the cgroup (mem-per-cpu × cpus) rather than node RAM. Tracks the #SBATCH
# directives above and survives the per-srun `env -u` below.
export TASK_MEM_MB=$(( ${SLURM_MEM_PER_CPU:-0} * ${SLURM_CPUS_PER_TASK:-1} ))
# NOTE: do NOT unset the SLURM mem vars here. A job step that inherits no memory
# request is granted the job's ENTIRE allocation, so only 1-2 of the --ntasks
# steps can ever run and the rest spin in "step creation still disabled,
# retrying (Requested nodes are busy)" for hours. Each srun below asks for its
# own --mem-per-cpu, and `env -u ...` strips the vars for R only, so terra still
# sizes memmax from TASK_MEM_MB rather than node RAM.

echo "=== NAIP processing ==="
for number in "${include[@]}"; do
    echo "  Cluster $number – NAIP"
    srun --nodes=1 --ntasks=1 --exclusive --mem-per-cpu=48G --cpus-per-task=1 \
        env -u SLURM_MEM_PER_CPU -u SLURM_MEM_PER_NODE -u SLURM_MEM_PER_GPU \
        Rscript R_Code_Analysis/NAIP_Processing_CMD.R \
        "$GPKG" \
        "$number" \
        "Data/NAIP/HUC_NAIP_Processed/" \
        >> "Shell_Scripts/logs/naip_${number}_${DATE}.log" 2>&1 &
done

wait
echo "NAIP processing completed."
