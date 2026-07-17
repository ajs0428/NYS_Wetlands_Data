#!/bin/bash -l
#SBATCH --partition=R256C128
#SBATCH --nodelist=cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem-per-cpu=32G
#SBATCH --job-name=hydro
#SBATCH --ntasks=5
# WhiteboxTools fill/breach panic ("Error unwrapping 'output'") near-100% of
# the time in a 1-CPU cgroup: worker threads drop their Arc<Raster> only AFTER
# tx.send(), and on one CPU the woken main thread preempts them right at the
# Arc::try_unwrap. >=2 CPUs makes the race vanish. Keep cpus-per-task >= 2 for
# any WBT-calling step; 32G x 2 preserves the 64G/task budget via TASK_MEM_MB.
#SBATCH --cpus-per-task=2
#SBATCH --output=Shell_Scripts/SLURM/slurm-hydro-%j.out


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

for number in "${include[@]}"; do
    echo "  Cluster $number – Hydro"
    srun --nodes=1 --ntasks=1 --cpus-per-task="${SLURM_CPUS_PER_TASK:-2}" --exclusive \
        Rscript R_Code_Analysis/hydro_metrics_singleVect_CMD.R \
        "$GPKG" \
        "$number" \
        "Data/TerrainProcessed/HUC_DEMs/" \
        "Data/TerrainProcessed/HUC_Hydro/" \
        >> "Shell_Scripts/logs/hydro_${number}_${DATE}.log" 2>&1 &
done

wait
echo "Hydro processing completed."


# 
# # Define the list of numbers
# # include=(22 51 53 56 60 64 67 84 86 90 92 102 105 116 120 123 136 138 152 176 183 189 192 193 198 208 218 225 250 11 12)
# include=(64 67 82 95 218 225 240 250)
# # Loop through each number in the list
# for number in "${include[@]}"; do
#     echo "Running Rscript with argument: $number"
#     Rscript R_Code_Analysis/hydro_metrics_singleVect_CMD.R \
#     "Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg" \
#     "$number" \
#     "Data/TerrainProcessed/HUC_DEMs/" \
#     "Data/TerrainProcessed/HUC_Hydro/" >> "Shell_Scripts/logs/hydro_$(date +%Y%m%d).log" 2>&1 
#     
# done
# 
# echo "All Rscript executions completed."

