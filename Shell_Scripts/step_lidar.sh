#!/bin/bash -l
#SBATCH --nodelist=cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem-per-cpu=16G
#SBATCH --cpus-per-task=8
#SBATCH --job-name=lidar
#SBATCH --ntasks=2
#SBATCH --output=Shell_Scripts/SLURM/slurm-lidar-%j.out

cd /ibstorage/anthony/NYS_Wetlands_Data/
export TMPDIR=/ibstorage/anthony/tmp
module load R/4.4.3

IFS=',' read -ra include <<< "$1"
GPKG="Data/NY_HUCS/NY_Cluster_Zones_250_NAomit_6347.gpkg"
OUTDIR="Data/Lidar/Metrics"
INDEX_DIR="Data/Lidar/Indexes"
DATE=$(date +%Y%m%d)

# Cluster-to-index mapping
lidar_entries=(
    "208|NYS_Central_Finger_Lakes_2020.gpkg"
    "208|NYS_Cayuga_Oswego_2018.gpkg"
    "208|FEMA_2019.gpkg"
    "123|USGS_Lake_Ontario_Hudson_River_2022.gpkg"
    "123|USGS_2024.gpkg"
    "123|FEMA_Hudson_Hoosic_2012.gpkg"
    "123|NYS_Warren_Washington_Essex_2015.gpkg"
    "11|FEMA_2019.gpkg"
    "11|FEMA_Fulton_Saratoga_Herkimer_Franklin_2017.gpkg"
    "11|FEMA_Franklin_St_Lawrence_2016_17.gpkg"
)

echo "=== Lidar metrics ==="
for entry in "${lidar_entries[@]}"; do
    cluster="${entry%%|*}"
    index_file="${entry##*|}"
    for number in "${include[@]}"; do
        if [[ "$cluster" == "$number" ]]; then
            echo "  Cluster $cluster – $index_file"
            Rscript R_Code_Analysis/LIDAR_ftp.R \
                "$GPKG" \
                "$cluster" \
                "$INDEX_DIR/$index_file" \
                "$OUTDIR" \
                >> "Shell_Scripts/logs/lidar_${DATE}.log" 2>&1
            break
        fi
    done
done
echo "Lidar metrics completed."
