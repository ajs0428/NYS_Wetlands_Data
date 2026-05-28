#!/bin/bash -l
#SBATCH --nodelist=cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem-per-cpu=48G
#SBATCH --cpus-per-task=2
#SBATCH --job-name=patch
#SBATCH --ntasks=2
#SBATCH --ntasks-per-node=1
#SBATCH --output=Shell_Scripts/SLURM/slurm-patch-%j.out


cd /ibstorage/anthony/NYS_Wetlands_Data/

export TMPDIR=/ibstorage/anthony/tmp

module load R/4.4.3

source Shell_Scripts/batch_config.sh
include=("${batch1[@]}")

# Loop through each number in the list
for number in "${include[@]}"; do
    echo "Running Rscript with argument: $number"
    srun --nodes=1 --ntasks=1 --exclusive \
        Rscript R_Code_Analysis/Raster_ChipsPatches_DL.R \
        "Data/Training_Data/R_Patches_Vector_Reviewed/" \
        128 \
        "$number" >> "Shell_Scripts/logs/patch_${number}_$(date +%Y%m%d).log" 2>&1 &
done

wait
echo "All Rscript executions completed."
