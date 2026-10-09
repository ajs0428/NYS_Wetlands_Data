#!/bin/bash -l
#SBATCH --partition=R256C128
#SBATCH --nodelist=cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem-per-cpu=4G
#SBATCH --cpus-per-task=4
#SBATCH --job-name=vector-patch-raw
#SBATCH --ntasks=8
#SBATCH --output=Shell_Scripts/SLURM/slurm-vector-patch-raw-%j.out

# =============================================================================
# Generate vector training patches straight from a raw statewide wetland layer
# (R_Code_Analysis/Vector_ChipsPatches_fromRAW_DL.R), one srun per cluster.
# Output: Data/Training_Data/R_Patches_Vector_fromRAW/
#         <source>_cluster_<N>_huc_<HUCID>_256m[_BINARY].gpkg
# Existing output files are skipped, so a rerun only fills in missing HUCs.
#
# Usage:
#   sbatch Shell_Scripts/vector_chipspatches_fromraw_dl.sh [RAW_WETLANDS] [CLASS_SCHEME] [CLASS_FIELD] [CLUSTERS]
#
#   Each positional can also be given as an env var of the same name; the
#   positional wins. Pass "" for a positional to fall through to env/default.
#
#   RAW_WETLANDS  raw wetland gpkg. Default: Data/NWI/NY_NWI_6347.gpkg
#   CLASS_SCHEME  MULTICLASS (EMW/FSW/SSW/UPL) or BINARY (WET/UPL).
#                 Default: MULTICLASS
#   CLASS_FIELD   column holding the class code (NWI: ATTRIBUTE). NONE for
#                 sources without one (e.g. NYS Informational wetlands), which
#                 only works with BINARY. Default: ATTRIBUTE
#   CLUSTERS      comma-separated batch names from batch_config.sh and/or bare
#                 cluster numbers, e.g. "batch3", "batch1,batch2", "208,225".
#                 Default: batch1,batch2,batch3
#
#   DRYRUN=1      print the Rscript commands instead of running them.
#
# Examples:
#   sbatch Shell_Scripts/vector_chipspatches_fromraw_dl.sh                          # NWI multiclass, batch1-3
#   sbatch Shell_Scripts/vector_chipspatches_fromraw_dl.sh "" BINARY "" batch4      # NWI binary, batch4
#   sbatch Shell_Scripts/vector_chipspatches_fromraw_dl.sh \
#       Data/Laba_NYS_Info_Wetlands/Informational_Freshwater_Wetland_Mapping_-4832045112583547805.gpkg \
#       BINARY NONE batch1,batch2                                                 # Info wetlands
#   CLUSTERS=64 DRYRUN=1 bash Shell_Scripts/vector_chipspatches_fromraw_dl.sh      # preview
#
# Sizing: cluster 64 (8 HUCs) peaked at ~0.4 GB in ~15 s run sequentially, so
# 4 CPUs x 4G per cluster leaves plenty of headroom for the larger clusters.
# =============================================================================

cd /ibstorage/anthony/NYS_Wetlands_Data/

export TMPDIR=/ibstorage/anthony/tmp

module load R/4.4.3

# The 2026-07 image update left PROJ 9.6 on every node, which the default
# home library's terra/sf were not built against. The 4.4-R128C40 library has
# the matching rebuild (the name is historical -- it is needed cluster-wide).
export R_LIBS_USER="/home/ajs544/R/x86_64-pc-linux-gnu-library/4.4-R128C40:/home/ajs544/R/x86_64-pc-linux-gnu-library/4.4"

export TASK_MEM_MB=$(( ${SLURM_MEM_PER_CPU:-0} * ${SLURM_CPUS_PER_TASK:-1} ))
unset SLURM_MEM_PER_CPU SLURM_MEM_PER_NODE SLURM_MEM_PER_GPU

source Shell_Scripts/batch_config.sh

RAW_WETLANDS="${1:-${RAW_WETLANDS:-Data/NWI/NY_NWI_6347.gpkg}}"
CLASS_SCHEME="${2:-${CLASS_SCHEME:-MULTICLASS}}"
CLASS_FIELD="${3:-${CLASS_FIELD:-ATTRIBUTE}}"
CLUSTERS="${4:-${CLUSTERS:-batch1,batch2,batch3}}"
PATCH_RADIUS=128
DATE=$(date +%Y%m%d)

if [[ ! -f "$RAW_WETLANDS" ]]; then
    echo "ERROR: raw wetland file not found: $RAW_WETLANDS"; exit 1
fi
CLASS_SCHEME="${CLASS_SCHEME^^}"
if [[ "$CLASS_SCHEME" != "MULTICLASS" && "$CLASS_SCHEME" != "BINARY" ]]; then
    echo "ERROR: CLASS_SCHEME must be MULTICLASS or BINARY, got '$CLASS_SCHEME'"; exit 1
fi
if [[ "$CLASS_SCHEME" == "MULTICLASS" && "${CLASS_FIELD^^}" == "NONE" ]]; then
    echo "ERROR: MULTICLASS needs a CLASS_FIELD; use BINARY for sources without one"; exit 1
fi

# Resolve the cluster selection: each comma-separated token is a batch name
# from batch_config.sh (expanded) or a bare cluster number.
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
# de-duplicate so two sruns never race on the same cluster's output files
mapfile -t include < <(printf '%s\n' "${include[@]}" | sort -un)

# log tag keeps NWI/Info and multiclass/binary runs of one cluster apart
SRC_TAG=$(basename "$RAW_WETLANDS" .gpkg | cut -d_ -f1)
LOG_TAG="vector_patch_raw_${SRC_TAG}_${CLASS_SCHEME,,}"

echo "RAW_WETLANDS=${RAW_WETLANDS}"
echo "CLASS_SCHEME=${CLASS_SCHEME} CLASS_FIELD=${CLASS_FIELD}"
echo "CLUSTERS=${CLUSTERS}"
echo "${include[@]}"

# Track each srun's PID -> cluster so a failed Rscript is reported. A bare
# `wait` returns 0 regardless, which made a failed cluster look like success.
declare -A PID_CLUSTER=()
for number in "${include[@]}"; do
    log="Shell_Scripts/logs/${LOG_TAG}_${number}_${DATE}.log"
    cmd=(Rscript R_Code_Analysis/Vector_ChipsPatches_fromRAW_DL.R
        "$number" "$RAW_WETLANDS" "$PATCH_RADIUS" "$CLASS_SCHEME" "$CLASS_FIELD")
    if [[ -n "${DRYRUN:-}" ]]; then
        echo "DRYRUN: ${cmd[*]} >> $log"
        continue
    fi
    echo "Running Rscript with argument: $number"
    # Slurm 22.05: srun no longer inherits --cpus-per-task from sbatch.
    srun --nodes=1 --ntasks=1 --cpus-per-task="${SLURM_CPUS_PER_TASK:-1}" --exclusive "${cmd[@]}" >> "$log" 2>&1 &
    PID_CLUSTER[$!]=$number
done

FAILED=()
for pid in "${!PID_CLUSTER[@]}"; do
    if ! wait "$pid"; then
        number=${PID_CLUSTER[$pid]}
        echo "FAILED: cluster $number (see Shell_Scripts/logs/${LOG_TAG}_${number}_${DATE}.log)"
        FAILED+=("$number")
    fi
done

if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo "vector_chipspatches_fromraw finished with ${#FAILED[@]} failed cluster(s): ${FAILED[*]}"
    exit 1
fi
echo "All Rscript executions completed."
