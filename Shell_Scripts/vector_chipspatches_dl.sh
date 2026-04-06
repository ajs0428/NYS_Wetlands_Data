#!/bin/bash -l
#SBATCH --nodelist=cbsuxu08,cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem-per-cpu=24G
#SBATCH --cpus-per-task=4
#SBATCH --job-name=vector-patch
#SBATCH --ntasks=2
#SBATCH --ntasks-per-node=1
#SBATCH --output=Shell_Scripts/SLURM/slurm-vector-patch-%j.out


cd /ibstorage/anthony/NYS_Wetlands_Data/

export TMPDIR=/ibstorage/anthony/tmp

module load R/4.4.3

# Define the list of numbers
# include=(11 12 22 51 53 56 60 64 67 84 86 90 92 102 105 116 120 123 136 138 152 176 183 189 192 193 198 218 225 250)
include=(123)
# Loop through each number in the list
for number in "${include[@]}"; do
    echo "Running Rscript with argument: $number"
    srun --nodes=1 --ntasks=1 --exclusive \
        Rscript R_Code_Analysis/Vector_ChipsPatches_DL.R \
        "$number" \
        "Data/Training_Data/HUC_NWI_Processed/" \
        128 >> "Shell_Scripts/logs/vector_patch_$(date +%Y%m%d).log" 2>&1 &
    
done

wait
echo "All Rscript executions completed."

