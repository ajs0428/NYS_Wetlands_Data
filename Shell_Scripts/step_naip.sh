#!/bin/bash -l
#SBATCH --nodelist=cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem-per-cpu=64G
#SBATCH --cpus-per-task=2
#SBATCH --job-name=naip
#SBATCH --ntasks=2
#SBATCH --output=Shell_Scripts/SLURM/slurm-naip-%j.out

cd /ibstorage/anthony/NYS_Wetlands_Data/
export TMPDIR=/ibstorage/anthony/tmp
module load R/4.4.3

IFS=',' read -ra include <<< "$1"
GPKG="Data/NY_HUCS/NY_Cluster_Zones_250_NAomit_6347.gpkg"
DATE=$(date +%Y%m%d)

echo "=== NAIP processing ==="
for number in "${include[@]}"; do
    echo "  Cluster $number – NAIP"
    Rscript R_Code_Analysis/NAIP_Processing_CMD.R \
        "$GPKG" \
        "$number" \
        "Data/NAIP/HUC_NAIP_Processed/" \
        >> "Shell_Scripts/logs/naip_${DATE}.log" 2>&1
done
echo "NAIP processing completed."
