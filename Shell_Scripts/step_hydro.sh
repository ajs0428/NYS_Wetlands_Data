#!/bin/bash -l
#SBATCH --nodelist=cbsuxu06,cbsuxu07,cbsuxu08,cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem-per-cpu=64G
#SBATCH --job-name=hydro
#SBATCH --ntasks=5
#SBATCH --cpus-per-task=1
#SBATCH --ntasks-per-node=1
#SBATCH --output=Shell_Scripts/SLURM/slurm-hydro-%j.out


cd /ibstorage/anthony/NYS_Wetlands_Data/
export TMPDIR=/ibstorage/anthony/NYS_Wetlands_Data/Data/tmp/
module load R/4.4.3

IFS=',' read -ra include <<< "$1"
GPKG="Data/NY_HUCS/NY_Cluster_Zones_250_NAomit_6347.gpkg"
DATE=$(date +%Y%m%d)

unset SLURM_MEM_PER_CPU SLURM_MEM_PER_NODE SLURM_MEM_PER_GPU

for number in "${include[@]}"; do
    echo "  Cluster $number – Hydro"
    srun --nodes=1 --ntasks=1 --exclusive \
        Rscript R_Code_Analysis/hydro_metrics_singleVect_CMD.r \
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
#     Rscript R_Code_Analysis/hydro_metrics_singleVect_CMD.r \
#     "Data/NY_HUCS/NY_Cluster_Zones_250_NAomit_6347.gpkg" \
#     "$number" \
#     "Data/TerrainProcessed/HUC_DEMs/" \
#     "Data/TerrainProcessed/HUC_Hydro/" >> "Shell_Scripts/logs/hydro_$(date +%Y%m%d).log" 2>&1 
#     
# done
# 
# echo "All Rscript executions completed."

