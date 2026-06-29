#!/bin/bash -l
#SBATCH --partition=R256C128
#SBATCH --nodelist=cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem-per-cpu=16G
#SBATCH --cpus-per-task=3
#SBATCH --job-name=vector-patch
#SBATCH --ntasks=6
#SBATCH --output=Shell_Scripts/SLURM/slurm-vector-patch-%j.out


cd /ibstorage/anthony/NYS_Wetlands_Data

export TMPDIR=/ibstorage/anthony/tmp

module load R/4.4.3

#Batch import
source Shell_Scripts/batch_config.sh
include=("${batch2[@]}")

# Loop through each number in the list
for number in "${include[@]}"; do
    echo "Running Rscript with argument: $number"
    srun --nodes=1 --ntasks=1 --exclusive \
        Rscript R_Code_Analysis/Vector_ChipsPatches_DL.R \
        "$number" \
        "Data/Training_Data/HUC_NWI_Processed/" \
        128 >> "Shell_Scripts/logs/vector_patch_${number}_$(date +%Y%m%d).log" 2>&1 &
    
done

wait
echo "All Rscript executions completed."

