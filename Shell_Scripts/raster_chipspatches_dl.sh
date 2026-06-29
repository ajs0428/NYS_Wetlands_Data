#!/bin/bash -l
#SBATCH --partition=R256C128
#SBATCH --nodelist=cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem-per-cpu=48G
#SBATCH --cpus-per-task=1
#SBATCH --job-name=patch
#SBATCH --ntasks=8
#SBATCH --output=Shell_Scripts/SLURM/slurm-patch-%j.out

# =============================================================================
# Generate DL training patches for the clusters in batch1 (see batch_config.sh).
#
# Usage:
#   sbatch Shell_Scripts/raster_chipspatches_dl.sh [VECTOR_DIR]
#
#   VECTOR_DIR  patch vector source folder (positional $1).
#               Default: Data/Training_Data/R_Patches_Vector_Reviewed/  -> R_Patches/
#
# Examples:
#   sbatch Shell_Scripts/raster_chipspatches_dl.sh                                            # reviewed (default)
#   sbatch Shell_Scripts/raster_chipspatches_dl.sh Data/Training_Data/R_Patches_Vector_NWI/   # NWI -> R_Patches_NWI/
#
# Note: a non-existent VECTOR_DIR silently produces 0 patches (list.files() is
# empty, no error) -- tab-complete the path to avoid typos.
# =============================================================================

cd /ibstorage/anthony/NYS_Wetlands_Data/

export TMPDIR=/ibstorage/anthony/tmp

module load R/4.4.3

# Size terra/GDAL memory to the per-task cgroup (mem-per-cpu × cpus), not the
# node's physical RAM (~251G). Without this terra and the GDAL block cache size
# off node memory and the worker OOM-kills against the 48G cgroup. Mirrors the
# memory contract the step_*.sh stages enforce.
export TASK_MEM_MB=$(( ${SLURM_MEM_PER_CPU:-0} * ${SLURM_CPUS_PER_TASK:-1} ))
unset SLURM_MEM_PER_CPU SLURM_MEM_PER_NODE SLURM_MEM_PER_GPU

source Shell_Scripts/batch_config.sh
include=("${batch1[@]}" "${batch2[@]}")
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
