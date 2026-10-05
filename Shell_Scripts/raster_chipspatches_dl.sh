#!/bin/bash -l
#SBATCH --partition=R256C128
#SBATCH --nodelist=cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem-per-cpu=48G
#SBATCH --cpus-per-task=1
#SBATCH --job-name=patch
#SBATCH --ntasks=4
#SBATCH --output=Shell_Scripts/SLURM/slurm-patch-%j.out

# =============================================================================
# Generate DL training patches for a set of clusters (see batch_config.sh).
#
# Usage:
#   sbatch Shell_Scripts/raster_chipspatches_dl.sh [VECTOR_DIR] [REMOVE_EXISTING] [CLUSTERS]
#
#   VECTOR_DIR       patch vector source folder (positional $1).
#                    Default: Data/Training_Data/R_Patches_Vector_Reviewed/ -> R_Patches/
#   REMOVE_EXISTING  1/true to delete each HUC's already-written patch .tifs
#                    before regenerating them (positional $2, or the env var of
#                    the same name; the positional wins). Default 0 = resume,
#                    i.e. keep existing patches and only fill in missing ones.
#                    Use this after EDITING the vector data -- otherwise the
#                    file.exists() guard in the R script skips every patch that
#                    is already on disk and the edits never reach the rasters.
#                    The sweep is per HUC gpkg, so PatchGroups deleted from the
#                    new vector data don't survive as stale rasters. A HUC whose
#                    vector file was deleted entirely is never iterated over, so
#                    remove those patches by hand.
#   CLUSTERS         which clusters to run (positional $3, or the env var of the
#                    same name; the positional wins). Comma-separated list of
#                    batch names from batch_config.sh and/or bare cluster
#                    numbers, e.g. "batch3", "batch1,batch2", "208,225",
#                    "batch3,250". The token "vectors" expands to every
#                    cluster that has a gpkg in VECTOR_DIR (parsed from the
#                    <tag>_cluster_<N>_huc_<HUCID>_... filenames) -- use it for
#                    folders like R_Patches_Vector_Prod/ whose clusters are
#                    scattered across many batches. Default "batch1,batch2,batch3" -- the batches
#                    whose upstream sources (DEM/terrain/hydro/CHM) are fully
#                    built, so it matches what check_patch_vectors.sh checks by
#                    default. Leaving batch3 out of the default is what let
#                    cluster 204's NWI patches sit stale from 2026-08-12.
#                    NOTE the 18 batches are disjoint and cover 1-250 exactly
#                    once, so selections can be run concurrently.
#
# Examples:
#   sbatch Shell_Scripts/raster_chipspatches_dl.sh                                            # reviewed, batch1+batch2+batch3
#   sbatch Shell_Scripts/raster_chipspatches_dl.sh Data/Training_Data/R_Patches_Vector_NWI/   # NWI -> R_Patches_NWI/
#   REMOVE_EXISTING=1 sbatch Shell_Scripts/raster_chipspatches_dl.sh                          # force full rebuild
#   sbatch Shell_Scripts/raster_chipspatches_dl.sh Data/Training_Data/R_Patches_Vector_NWI/ 1 # NWI, forced rebuild
#   CLUSTERS=batch3 sbatch Shell_Scripts/raster_chipspatches_dl.sh                            # reviewed, batch3
#   sbatch Shell_Scripts/raster_chipspatches_dl.sh Data/Training_Data/R_Patches_Vector_NWI/ 0 225
#   sbatch Shell_Scripts/raster_chipspatches_dl.sh Data/Training_Data/R_Patches_Vector_Prod/ 0 vectors
#
# Band profile: R_Patches_Vector_Prod/ automatically builds the "prod" stack
# (no ortho/lidar, NAIP keeps ndvi/ndwi); every other folder builds the
# "factorial" stack. Override with HUC_STACK_PROFILE=<name> (see
# stack_profiles() in R_Code_Analysis/huc_stack.R).
#
# Note: a non-existent VECTOR_DIR aborts the job up front (the R script alone
# would silently produce 0 patches).
# =============================================================================

cd /ibstorage/anthony/NYS_Wetlands_Data/

export TMPDIR=/ibstorage/anthony/tmp

module load R/4.4.3

# The 2026-07 image update left PROJ 9.6 on every node, which the default
# home library's terra/sf were not built against. The 4.4-R128C40 library has
# the matching rebuild (the name is historical -- it is needed cluster-wide);
# everything else falls through to the default library.
export R_LIBS_USER="/home/ajs544/R/x86_64-pc-linux-gnu-library/4.4-R128C40:/home/ajs544/R/x86_64-pc-linux-gnu-library/4.4"

# Size terra/GDAL memory to the per-task cgroup (mem-per-cpu × cpus), not the
# node's physical RAM (~251G). Without this terra and the GDAL block cache size
# off node memory and the worker OOM-kills against the 48G cgroup. Mirrors the
# memory contract the step_*.sh stages enforce.
export TASK_MEM_MB=$(( ${SLURM_MEM_PER_CPU:-0} * ${SLURM_CPUS_PER_TASK:-1} ))
unset SLURM_MEM_PER_CPU SLURM_MEM_PER_NODE SLURM_MEM_PER_GPU

# Positional $2 overrides the inherited env var (sbatch --export=ALL is the
# default, so REMOVE_EXISTING=1 sbatch ... already reaches this job). Exported
# so the srun'd Rscript workers see it.
export REMOVE_EXISTING="${2:-${REMOVE_EXISTING:-0}}"
echo "REMOVE_EXISTING=${REMOVE_EXISTING}"

source Shell_Scripts/batch_config.sh

VECTOR_DIR="${1:-Data/Training_Data/R_Patches_Vector_Reviewed/}"
if [[ ! -d "$VECTOR_DIR" ]]; then
    echo "ERROR: vector directory not found: $VECTOR_DIR"; exit 1
fi

# Resolve the cluster selection: positional $3 beats the CLUSTERS env var,
# which beats the batch1+batch2+batch3 default. Each comma-separated token is
# "vectors" (every cluster with a gpkg in VECTOR_DIR), a batch name from
# batch_config.sh (expanded), or a bare cluster number.
CLUSTERS="${3:-${CLUSTERS:-batch1,batch2,batch3}}"
include=()
IFS=',' read -ra tokens <<< "$CLUSTERS"
for token in "${tokens[@]}"; do
    token="${token//[[:space:]]/}"
    [[ -z "$token" ]] && continue
    if [[ "${token,,}" == "vectors" ]]; then
        mapfile -t expanded < <(ls "$VECTOR_DIR" | grep -E '\.gpkg$' \
            | sed -nE 's/.*cluster_([0-9]+)_huc_.*/\1/p' | sort -un)
        if [[ ${#expanded[@]} -eq 0 ]]; then
            echo "ERROR: no <tag>_cluster_<N>_huc_... gpkgs in $VECTOR_DIR"; exit 1
        fi
        include+=("${expanded[@]}")
    elif [[ "$token" =~ ^batch[0-9]+$ ]]; then
        ref="$token[@]"
        expanded=("${!ref}")
        if [[ ${#expanded[@]} -eq 0 ]]; then
            echo "ERROR: '$token' is not defined in batch_config.sh"; exit 1
        fi
        include+=("${expanded[@]}")
    elif [[ "$token" =~ ^[0-9]+$ ]]; then
        include+=("$token")
    else
        echo "ERROR: '$token' is neither a batch name nor a cluster number"; exit 1
    fi
done
if [[ ${#include[@]} -eq 0 ]]; then
    echo "ERROR: CLUSTERS='$CLUSTERS' selected no clusters"; exit 1
fi
# de-duplicate: "vectors" or a bare number can repeat a batch's clusters, and
# two sruns on the same cluster would race on the same output files
mapfile -t include < <(printf '%s\n' "${include[@]}" | sort -un)

echo "CLUSTERS=${CLUSTERS}"
echo "${include[@]}"
# Loop through each number in the list
for number in "${include[@]}"; do
    echo "Running Rscript with argument: $number"
    srun --nodes=1 --ntasks=1 --exclusive \
        Rscript R_Code_Analysis/Raster_ChipsPatches_DL.R \
        "$VECTOR_DIR" \
        128 \
        "$number" >> "Shell_Scripts/logs/patch_${number}_$(date +%Y%m%d).log" 2>&1 &
done

wait
echo "All Rscript executions completed."
