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

cd /ibstorage/anthony/NYS_Wetlands_Data/
export TMPDIR=/ibstorage/anthony/NYS_Wetlands_Data/Data/tmp/
module load R/4.4.3

IFS=',' read -ra include <<< "$1"
metric="${2:-slp}"
DATE=$(date +%Y%m%d)

# Snapshot the per-task memory budget (MB) before unsetting the SLURM mem vars,
# so the R step can size terra::memmax to the cgroup (mem-per-cpu × cpus) rather
# than node RAM. Tracks the #SBATCH directives above and survives the unset.
export TASK_MEM_MB=$(( ${SLURM_MEM_PER_CPU:-0} * ${SLURM_CPUS_PER_TASK:-1} ))
unset SLURM_MEM_PER_CPU SLURM_MEM_PER_NODE SLURM_MEM_PER_GPU

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
