#!/bin/bash -l
#SBATCH --nodelist=cbsuxu06,cbsuxu07,cbsuxu08,cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem-per-cpu=64G
#SBATCH --job-name=lidar
#SBATCH --cpus-per-task=1
#SBATCH --ntasks=5
#SBATCH --ntasks-per-node=1
#SBATCH --output=Shell_Scripts/SLURM/slurm-lidar-%j.out

cd /ibstorage/anthony/NYS_Wetlands_Data/
export TMPDIR=/ibstorage/anthony/NYS_Wetlands_Data/Data/tmp/
module load R/4.4.3

IFS=',' read -ra include <<< "$1"
GPKG="Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg"
OUTDIR="Data/Lidar/HUC_Lidar_Metrics"
DATE=$(date +%Y%m%d)

unset SLURM_MEM_PER_CPU SLURM_MEM_PER_NODE SLURM_MEM_PER_GPU

echo "=== Lidar metrics ==="
for number in "${include[@]}"; do
        echo "Cluster $number"
        srun --nodes=1 --ntasks=1 --exclusive \
            Rscript R_Code_Analysis/Lidar_HUC_Processing.R \
            "$GPKG" \
            "$number" \
            "$OUTDIR" \
            >> "Shell_Scripts/logs/lidar_huc_${number}_$(date +%Y%m%d).log" 2>&1 &
done

wait
echo "Lidar metrics completed."
