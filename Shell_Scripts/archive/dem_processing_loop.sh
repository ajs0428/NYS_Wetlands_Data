#!/bin/bash -l
#SBATCH --nodelist=cbsuxu04,cbsuxu05,cbsuxu06,cbsuxu07,cbsuxu08
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem-per-cpu=36G
#SBATCH --cpus-per-task=2
#SBATCH --job-name=dem_processing
#SBATCH --ntasks=5
#SBATCH --ntasks-per-node=1
#SBATCH --output=Shell_Scripts/SLURM/slurm-dems-%j.out

cd /ibstorage/anthony/NYS_Wetlands_Data/

export TMPDIR=/ibstorage/anthony/tmp

module load R/4.4.3

#Batch import
source Shell_Scripts/batch_config.sh
include=("${batch1[@]}")


# Loop through each number in the list
for number in "${include[@]}"; do
    echo "Running Rscript with argument: $number"
    
    srun --nodes=1 --ntasks=1 --exclusive \
    Rscript R_Code_Analysis/DEM_Extract_singleVect_CMD.R \
        "Data/NYS_DEM_Indexes" \
        "Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg" \
        "$number" \
        "Data/DEMs/" \
        "Data/TerrainProcessed/HUC_DEMs/" >> "Shell_Scripts/logs/dem_processing_${number}_$(date +%Y%m%d).log" 2>&1 &

done

wait


