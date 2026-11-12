#!/bin/bash -l
#SBATCH --partition=R256C128
#SBATCH --nodelist=cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem-per-cpu=8G
#SBATCH --cpus-per-task=16
#SBATCH --job-name=training_data_gen
#SBATCH --ntasks=2
#SBATCH --output=Shell_Scripts/SLURM/slurm-train-%j.out

cd /ibstorage/anthony/NYS_Wetlands_Data

export TMPDIR=/ibstorage/anthony/tmp

module load R/4.4.3

#Batch import
source Shell_Scripts/batch_config.sh
include=("${batch2[@]}")

for number in "${include[@]}"; do
    echo "Running Rscript with argument: $number"
    Rscript R_Code_Analysis/TrainingDataGenerationFlex_CMD.R \
    "Data/NWI/NY_NWI_6347.gpkg" \
	  "$GPKG" \
	  "WETLAND_TY" \
	  "$number" >> "Shell_Scripts/logs/training_data_gen_$(date +%Y%m%d).log" 2>&1
done



