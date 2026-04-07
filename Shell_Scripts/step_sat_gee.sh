#!/bin/bash -l
#SBATCH --nodelist=cbsuxu06,cbsuxu07,cbsuxu08,cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem-per-cpu=32G
#SBATCH --job-name=sat_gee
#SBATCH --ntasks=5
#SBATCH --ntasks-per-node=1
#SBATCH --output=Shell_Scripts/SLURM/slurm-sat-gee-%j.out
#SBATCH --time=48:00:00

cd /ibstorage/anthony/NYS_Wetlands_Data/
export TMPDIR=/ibstorage/anthony/NYS_Wetlands_Data/Data/tmp/
module load R/4.4.3

IFS=',' read -ra include <<< "$1"
DATE=$(date +%Y%m%d)

echo "=== Sentinel GEE processing ==="
for number in "${include[@]}"; do
    echo "  Cluster $number – Sentinel GEE"
    srun --nodes=1 --ntasks=1 --exclusive \
        Rscript R_Code_Analysis/Sentinel_FromGEE_Processing.R \
        "Data/TerrainProcessed/HUC_DEMs/" \
        "Data/Satellite/GEE_Download_NY_HUC_Sentinel_Indices/ny_huc_indices" \
        "Data/Satellite/HUC_Processed_NY_Sentinel_Indices/" \
        "$number" \
        >> "Shell_Scripts/logs/sat_gee_${number}_${DATE}.log" 2>&1 &
done

wait
echo "Sentinel GEE processing completed."
