#!/bin/bash -l
#SBATCH --partition=R128C40
#SBATCH --nodelist=cbsuxu05,cbsuxu06,cbsuxu07,cbsuxu08 
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
#                    "batch3,250". Default "batch1,batch2,batch3" -- the batches
#                    whose upstream sources (DEM/terrain/hydro/CHM) are fully
#                    built, so it matches what check_patch_vectors.sh checks by
#                    default. Leaving batch3 out of the default is what let
#                    cluster 204's NWI patches sit stale from 2026-08-12.
#                    NOTE batch1-3 overlap batch4-18 -- don't run overlapping
#                    selections concurrently (see batch_config.sh).
#
# Examples:
#   sbatch Shell_Scripts/raster_chipspatches_dl.sh                                            # reviewed, batch1+batch2+batch3
#   sbatch Shell_Scripts/raster_chipspatches_dl.sh Data/Training_Data/R_Patches_Vector_NWI/   # NWI -> R_Patches_NWI/
#   REMOVE_EXISTING=1 sbatch Shell_Scripts/raster_chipspatches_dl.sh                          # force full rebuild
#   sbatch Shell_Scripts/raster_chipspatches_dl.sh Data/Training_Data/R_Patches_Vector_NWI/ 1 # NWI, forced rebuild
#   CLUSTERS=batch3 sbatch Shell_Scripts/raster_chipspatches_dl.sh                            # reviewed, batch3
#   sbatch Shell_Scripts/raster_chipspatches_dl.sh Data/Training_Data/R_Patches_Vector_NWI/ 0 225
#
# Note: a non-existent VECTOR_DIR silently produces 0 patches (list.files() is
# empty, no error) -- tab-complete the path to avoid typos.
# =============================================================================

cd /ibstorage/anthony/NYS_Wetlands_Data/

export TMPDIR=/ibstorage/anthony/tmp

module load R/4.4.3

# The R128C40 nodes (cbsuxu01-08) image ships GDAL 3.4/PROJ 9.6, not the
# GDAL/PROJ sonames terra+sf in the default home library were built against on
# cbsuxu09/10 (libproj.so.22/libgdal.so.31). A partition-specific rebuild of
# terra and sf lives in 4.4-R128C40; everything else falls through to the
# default library.
if [[ "${SLURM_JOB_PARTITION:-}" == "R128C40" ]]; then
    export R_LIBS_USER="/home/ajs544/R/x86_64-pc-linux-gnu-library/4.4-R128C40:/home/ajs544/R/x86_64-pc-linux-gnu-library/4.4"
fi

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

# Resolve the cluster selection: positional $3 beats the CLUSTERS env var,
# which beats the batch1+batch2 default. Each comma-separated token is either a
# batch name from batch_config.sh (expanded) or a bare cluster number.
CLUSTERS="${3:-${CLUSTERS:-batch1,batch2,batch3}}"
include=()
IFS=',' read -ra tokens <<< "$CLUSTERS"
for token in "${tokens[@]}"; do
    token="${token//[[:space:]]/}"
    [[ -z "$token" ]] && continue
    if [[ "$token" =~ ^batch[0-9]+$ ]]; then
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

echo "CLUSTERS=${CLUSTERS}"
echo "${include[@]}"
# Loop through each number in the list
for number in "${include[@]}"; do
    echo "Running Rscript with argument: $number"
    srun --nodes=1 --ntasks=1 --exclusive \
        Rscript R_Code_Analysis/Raster_ChipsPatches_DL.R \
        "${1:-Data/Training_Data/R_Patches_Vector_Reviewed/}" \
        128 \
        "$number" >> "Shell_Scripts/logs/patch_${number}_$(date +%Y%m%d).log" 2>&1 &
done

wait
echo "All Rscript executions completed."
