#!/bin/bash -l
#SBATCH --nodelist=cbsuxu06,cbsuxu07,cbsuxu08,cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem-per-cpu=12G
#SBATCH --cpus-per-task=2
#SBATCH --job-name=precheck
#SBATCH --ntasks=5
#SBATCH --ntasks-per-node=1
#SBATCH --output=Shell_Scripts/SLURM/slurm-precheck-%j.out

cd /ibstorage/anthony/NYS_Wetlands_Data/

export TMPDIR=/ibstorage/anthony/tmp

module load R/4.4.3

# Define the list of numbers
# include=(11 12 22 46 50 51 53 56 60 64 67 84 86 90 92 102 105 116 120 123 126 136 138 152 176 183 187 189 192 193 198 203 208 218 225 240 250)
### Batch 1
include=(11 22 46 50 64 67 82 95 123 168 208 218 225 250)
# Loop through each number in the list
for number in "${include[@]}"; do
    echo "Running Rscript with argument: $number"
    # srun --nodes=1 --ntasks=1 --exclusive \
        Rscript R_Code_Analysis/PreCheck_Missing_HUCs.R \
        "$number" \
        "Data/HUC_Raster_Stacks/HUC_DL_Stacks/" >> "Shell_Scripts/logs/precheck_${number}_$(date +%Y%m%d).log" 2>&1 &
done

wait
echo "All PreCheck Rscripts executions completed."

