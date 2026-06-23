#!/bin/bash -l
#SBATCH --nodelist=cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem-per-cpu=16G
#SBATCH --cpus-per-task=5
#SBATCH --job-name=wet_rcl
#SBATCH --ntasks=2
#SBATCH --output=Shell_Scripts/SLURM/slurm-nwi-rcl-%j.out

cd /ibstorage/anthony/NYS_Wetlands_Data

export TMPDIR=/ibstorage/anthony/tmp

module load R/4.4.3

#Batch import
source Shell_Scripts/batch_config.sh
include=("${batch2[@]}")

# Loop through each number in the list
for number in "${include[@]}"; do
    echo "Running Rscript with argument: $number"
    Rscript R_Code_Analysis/Wetlands_CHM_reclass.R \
    "$number" \
    "Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg" \
    "Data/NWI/NY_NWI_6347.gpkg" \
    "ATTRIBUTE" >> "Shell_Scripts/logs/wet_rcl_$(date +%Y%m%d).log" 2>&1 
    
done

echo "All NWI CHM reclassify Rscripts executions completed."

