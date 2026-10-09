#!/bin/bash -l
#SBATCH --partition=R256C128
#SBATCH --nodelist=cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem-per-cpu=36G
#SBATCH --job-name=chm
#SBATCH --cpus-per-task=2
#SBATCH --ntasks=5
#SBATCH --output=Shell_Scripts/SLURM/slurm-chm-%j.out

cd /ibstorage/anthony/NYS_Wetlands_Data/
export TMPDIR=/ibstorage/anthony/NYS_Wetlands_Data/Data/tmp/
module load R/4.4.3

IFS=',' read -ra include <<< "$1"
GPKG="Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg"
DATE=$(date +%Y%m%d)

# Snapshot the per-task memory budget (MB) before unsetting the SLURM mem vars,
# so the R step can size terra::memmax to the cgroup (mem-per-cpu × cpus) rather
# than node RAM. Tracks the #SBATCH directives above and survives the unset.
export TASK_MEM_MB=$(( ${SLURM_MEM_PER_CPU:-0} * ${SLURM_CPUS_PER_TASK:-1} ))
unset SLURM_MEM_PER_CPU SLURM_MEM_PER_NODE SLURM_MEM_PER_GPU

echo "=== CHM extraction ==="
# Track each srun's PID -> cluster so a failed Rscript is reported. A bare
# `wait` returns 0 regardless, which made a failed cluster look like success.
declare -A PID_CLUSTER=()
for number in "${include[@]}"; do
    echo "  Cluster $number – CHM"
    # Slurm 22.05: srun no longer inherits --cpus-per-task from sbatch.
    srun --nodes=1 --ntasks=1 --cpus-per-task="${SLURM_CPUS_PER_TASK:-1}" --exclusive \
        Rscript R_Code_Analysis/CHM_extraction.R \
        "$GPKG" \
        "$number" \
        "Data/CHMs/AWS" \
        >> "Shell_Scripts/logs/chm_${number}_${DATE}.log" 2>&1 &
    PID_CLUSTER[$!]=$number
done

FAILED=()
for pid in "${!PID_CLUSTER[@]}"; do
    if ! wait "$pid"; then
        c=${PID_CLUSTER[$pid]}
        echo "FAILED: cluster $c (see Shell_Scripts/logs/chm_${c}_${DATE}.log)"
        FAILED+=("$c")
    fi
done

if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo "CHM extraction finished with ${#FAILED[@]} failed cluster(s): ${FAILED[*]}"
    exit 1
fi
echo "CHM extraction completed."
