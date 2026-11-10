#!/bin/bash -l
#SBATCH --partition=R256C128
#SBATCH --nodelist=cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem-per-cpu=12G
#SBATCH --cpus-per-task=8
#SBATCH --ntasks=1
#SBATCH --job-name=inference-patch
#SBATCH --output=Shell_Scripts/SLURM/slurm-inference-patch-%j.out

# =============================================================================
# Vector patches (256 m squares) from multiclass DL inference rasters, for QGIS
# review before they enter Prod training. Raster counterpart of
# vector_chipspatches_dl.sh; see R_Code_Analysis/Inference_ChipsPatches_DL.R.
#
# Usage:
#   sbatch Shell_Scripts/inference_chipspatches_dl.sh [PRED_DIR] [MAX_PATCHES] [CLUSTERS] [OVERWRITE] [POLY_RES]
#     PRED_DIR     default ../NYS_Wetlands_DL/Data/HUC_DL_Predictions_v3_masked/
#     MAX_PATCHES  per HUC, default 25
#     CLUSTERS     "all" (default) or comma list, e.g. "11,102"
#     OVERWRITE    1 to rewrite existing gpkgs (default 0 = skip them)
#     POLY_RES     polygonizing resolution in 1 m pixels (default 1 = exact;
#                  2 = 2 m modal, ~half the vertices, ~1% of pixels relabelled)
#
# Output: Data/Training_Data/R_Patches_Vector_Inference/DLv3_cluster_<N>_huc_<HUC>_256m.gpkg
# After review, rasterize with the prod stack (-> R_Patches_Inference/):
#   sbatch Shell_Scripts/raster_chipspatches_dl.sh Data/Training_Data/R_Patches_Vector_Inference/ 0 vectors
# =============================================================================

cd /ibstorage/anthony/NYS_Wetlands_Data

PRED_DIR="${1:-../NYS_Wetlands_DL/Data/HUC_DL_Predictions_v3_masked/}"
MAX_PATCHES="${2:-25}"
CLUSTERS="${3:-all}"
OVERWRITE="${4:-0}"
POLY_RES="${5:-1}"

# terra memmax is sized from the cgroup budget, not node RAM
export TASK_MEM_MB=$(( ${SLURM_MEM_PER_CPU:-12288} * ${SLURM_CPUS_PER_TASK:-1} ))
unset SLURM_MEM_PER_CPU SLURM_MEM_PER_NODE SLURM_MEM_PER_GPU

export TMPDIR=/ibstorage/anthony/tmp
module load R/4.4.3
mkdir -p Shell_Scripts/logs

Rscript R_Code_Analysis/Inference_ChipsPatches_DL.R \
    "$PRED_DIR" 128 "$MAX_PATCHES" "$CLUSTERS" "$OVERWRITE" \
    Data/Training_Data/R_Patches_Vector_Inference/ "$POLY_RES" \
    >> "Shell_Scripts/logs/inference_patch_$(date +%Y%m%d).log" 2>&1

echo "Inference patch generation completed."
