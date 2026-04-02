#!/bin/bash -l
#SBATCH --nodelist=cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem-per-cpu=36G
#SBATCH --cpus-per-task=4
#SBATCH --job-name=chm
#SBATCH --ntasks=2
#SBATCH --output=Shell_Scripts/SLURM/slurm-chm-%j.out

cd /ibstorage/anthony/NYS_Wetlands_Data/
export TMPDIR=/ibstorage/anthony/tmp
module load R/4.4.3

IFS=',' read -ra include <<< "$1"
GPKG="Data/NY_HUCS/NY_Cluster_Zones_250_NAomit_6347.gpkg"
DATE=$(date +%Y%m%d)

echo "=== CHM extraction ==="
for number in "${include[@]}"; do
    echo "  Cluster $number – CHM"
    Rscript R_Code_Analysis/CHM_extraction.R \
        "$GPKG" \
        "$number" \
        "Data/CHMs/AWS" \
        >> "Shell_Scripts/logs/chm_${DATE}.log" 2>&1
done
echo "CHM extraction completed."
