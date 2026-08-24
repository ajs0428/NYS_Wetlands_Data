#!/bin/bash -l
# =============================================================================
# Status report for the DL patch vector gpkgs.
#
# Read-only. Applies the SAME cleaning + filtering as Raster_ChipsPatches_DL.R
# (both source R_Code_Analysis/patch_groups.R), so the report predicts exactly
# what a patch run will write. Use it BEFORE launching
# raster_chipspatches_dl.sh to catch bad vector data cheaply.
#
# Runs on the login node -- it only reads vector geometry and raster headers, so
# there is no sbatch here.
#
# Usage:
#   bash Shell_Scripts/check_patch_vectors.sh [VECTOR_DIR] [CLUSTERS] [REPORT]
#
#   VECTOR_DIR  patch vector source folder (positional $1).
#               Default: Data/Training_Data/R_Patches_Vector_Reviewed/
#               The raster folder to reconcile against is derived from it, the
#               same way the rasterizer derives it:
#                 R_Patches_Vector_Reviewed/ -> R_Patches/
#                 R_Patches_Vector_NWI/      -> R_Patches_NWI/
#                 R_Patches_Vector_NWIextra/ -> R_Patches_NWIextra/
#   CLUSTERS    which clusters to check (positional $2, or the env var of the
#               same name; the positional wins). Comma-separated batch names
#               from batch_config.sh and/or bare cluster numbers, or "all".
#               Default "batch1,batch2,batch3" -- the batches whose upstream
#               sources are fully built.
#   REPORT      output .txt path (positional $3). Default
#               Shell_Scripts/logs/patch_vector_check_<folder>_<date>.txt
#
#   SKIP_RASTER_CHECK=1  skip opening every .tif to verify 256x256 (faster).
#
# Examples:
#   bash Shell_Scripts/check_patch_vectors.sh
#   bash Shell_Scripts/check_patch_vectors.sh Data/Training_Data/R_Patches_Vector_NWI/
#   bash Shell_Scripts/check_patch_vectors.sh Data/Training_Data/R_Patches_Vector_NWI/ all
#   bash Shell_Scripts/check_patch_vectors.sh Data/Training_Data/R_Patches_Vector_Reviewed/ 208,225
#   SKIP_RASTER_CHECK=1 bash Shell_Scripts/check_patch_vectors.sh
#
#   # one batch, report named after it (REPORT is $3, so $1 and $2 must be given):
#   bash Shell_Scripts/check_patch_vectors.sh \
#       Data/Training_Data/R_Patches_Vector_Reviewed/ batch4 \
#       Shell_Scripts/logs/patch_vector_check_Reviewed_batch4.txt
#
#   # several batches plus a loose cluster, into a per-run report:
#   bash Shell_Scripts/check_patch_vectors.sh \
#       Data/Training_Data/R_Patches_Vector_NWI/ batch5,batch6,225 \
#       Shell_Scripts/logs/patch_vector_check_NWI_batch5-6.txt
#
#   # same selection via the env var (report then falls back to the dated default):
#   CLUSTERS=batch7,batch8 bash Shell_Scripts/check_patch_vectors.sh
#
# Exit codes: 0 = clean, 1 = flags/mismatches found, 2 = usage/setup error.
# =============================================================================

set -uo pipefail

cd /ibstorage/anthony/NYS_Wetlands_Data/ || exit 2

export TMPDIR=/ibstorage/anthony/tmp

module load R/4.4.3

# The 2026-07 image update left PROJ 9.6 on every node, which the default
# home library's terra/sf were not built against. The 4.4-R128C40 library has
# the matching rebuild; everything else falls through to the default.
export R_LIBS_USER="/home/ajs544/R/x86_64-pc-linux-gnu-library/4.4-R128C40:/home/ajs544/R/x86_64-pc-linux-gnu-library/4.4"

VECTOR_DIR="${1:-Data/Training_Data/R_Patches_Vector_Reviewed/}"
if [[ ! -d "$VECTOR_DIR" ]]; then
    echo "ERROR: vector directory not found: $VECTOR_DIR" >&2
    exit 2
fi

source Shell_Scripts/batch_config.sh

# Resolve the cluster selection: positional $2 beats the CLUSTERS env var, which
# beats the batch1+batch2+batch3 default. Each comma-separated token is either
# "all", a batch name from batch_config.sh, or a bare cluster number.
CLUSTERS="${2:-${CLUSTERS:-batch1,batch2,batch3}}"
if [[ "${CLUSTERS,,}" == "all" ]]; then
    CLUSTER_LIST="all"
else
    include=()
    IFS=',' read -ra tokens <<< "$CLUSTERS"
    for token in "${tokens[@]}"; do
        token="${token//[[:space:]]/}"
        [[ -z "$token" ]] && continue
        if [[ "$token" =~ ^batch[0-9]+$ ]]; then
            ref="$token[@]"
            expanded=("${!ref}")
            if [[ ${#expanded[@]} -eq 0 ]]; then
                echo "ERROR: '$token' is not defined in batch_config.sh" >&2; exit 2
            fi
            include+=("${expanded[@]}")
        elif [[ "$token" =~ ^[0-9]+$ ]]; then
            include+=("$token")
        else
            echo "ERROR: '$token' is neither a batch name nor a cluster number" >&2
            exit 2
        fi
    done
    if [[ ${#include[@]} -eq 0 ]]; then
        echo "ERROR: CLUSTERS='$CLUSTERS' selected no clusters" >&2; exit 2
    fi
    # de-duplicate: batches are disjoint, but a bare number can repeat a batch's
    CLUSTER_LIST=$(printf '%s\n' "${include[@]}" | sort -un | paste -sd,)
fi

LOGDIR="Shell_Scripts/logs"
mkdir -p "$LOGDIR"
FOLDER_TAG=$(basename "${VECTOR_DIR%/}")
REPORT="${3:-$LOGDIR/patch_vector_check_${FOLDER_TAG}_$(date +%Y%m%d_%H%M%S).txt}"

CHECK_RASTERS=1
[[ "${SKIP_RASTER_CHECK:-0}" == "1" ]] && CHECK_RASTERS=0

echo "Vector folder : $VECTOR_DIR"
echo "Clusters      : $CLUSTERS"
echo "Report        : $REPORT"
echo

Rscript R_Code_Analysis/Check_Patch_Vectors.R \
    "$VECTOR_DIR" \
    "$CLUSTER_LIST" \
    "$REPORT" \
    "$CHECK_RASTERS"
rc=$?
if [[ $rc -ne 0 ]]; then
    echo "ERROR: Check_Patch_Vectors.R failed (exit $rc)" >&2
    exit 2
fi

# Non-zero exit when the report found anything, so this can gate a rebuild:
#   bash Shell_Scripts/check_patch_vectors.sh && sbatch Shell_Scripts/raster_chipspatches_dl.sh
if grep -q "^STATUS: OK" "$REPORT"; then
    exit 0
fi
exit 1
