#!/bin/bash -l
#SBATCH --nodelist=cbsuxu06,cbsuxu07,cbsuxu08,cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem-per-cpu=84G
#SBATCH --cpus-per-task=1
#SBATCH --job-name=lidar_huc
#SBATCH --ntasks=5
#SBATCH --ntasks-per-node=1
#SBATCH --output=Shell_Scripts/SLURM/slurm-lidar-huc-%j.out

cd /ibstorage/anthony/NYS_Wetlands_Data/

export TMPDIR=/ibstorage/anthony/NYS_Wetlands_Data/Data/tmp/

module load R/4.4.3

#Batch import
source Shell_Scripts/batch_config.sh
include=("${batch1[@]}")

for number in "${include[@]}"; do
    echo "Running Rscript with argument: $number"
    srun --nodes=1 --ntasks=1 --exclusive \
        Rscript R_Code_Analysis/Lidar_HUC_Processing.R \
        "Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg" \
        "$number" \
        "Data/Lidar/HUC_Lidar_Metrics/" >> "Shell_Scripts/logs/lidar_huc_${number}_$(date +%Y%m%d).log" 2>&1 &
done

wait
echo "All Lidar HUC Rscripts executions completed."
