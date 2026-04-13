#!/bin/bash -l
#SBATCH --nodelist=cbsuxu04,cbsuxu05,cbsuxu06,cbsuxu07,cbsuxu08,cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem-per-cpu=32G
#SBATCH --cpus-per-task=2
#SBATCH --job-name=dem_processing
#SBATCH --ntasks=7
#SBATCH --ntasks-per-node=1
#SBATCH --output=Shell_Scripts/SLURM/slurm-dems-%j.out

cd /ibstorage/anthony/NYS_Wetlands_Data/
export TMPDIR=/ibstorage/anthony/NYS_Wetlands_Data/Data/tmp/
module load R/4.4.3

IFS=',' read -ra include <<< "$1"
GPKG="Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg"
DATE=$(date +%Y%m%d)

unset SLURM_MEM_PER_CPU SLURM_MEM_PER_NODE SLURM_MEM_PER_GPU

echo "=== CHM extraction ==="
for number in "${include[@]}"; do
    echo "  Cluster $number – CHM"
    srun --nodes=1 --ntasks=1 --exclusive \
        Rscript R_Code_Analysis/DEM_Extract_singleVect_CMD.r \
        "Data/NYS_DEM_Indexes" \
        "$GPKG" \
        "$number" \
        "Data/DEMs/" \
        "Data/TerrainProcessed/HUC_DEMs/" \
        >> "Shell_Scripts/logs/dem_${number}_${DATE}.log" 2>&1 &
done

wait
echo "DEM extraction completed."
