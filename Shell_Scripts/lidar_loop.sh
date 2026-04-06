#!/bin/bash -l
#SBATCH --nodelist=cbsuxu06,cbsuxu07,cbsuxu08,cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem-per-cpu=16G
#SBATCH --cpus-per-task=5
#SBATCH --job-name=lidar
#SBATCH --ntasks=5
#SBATCH --ntasks-per-node=1
#SBATCH --output=Shell_Scripts/SLURM/slurm-lidar-%j.out

cd /ibstorage/anthony/NYS_Wetlands_Data/

# srun --nodes=5 --ntasks=5 bash -c 'echo "Node $(hostname) reporting in"'

export TMPDIR=/ibstorage/anthony/tmp

module load R/4.4.3

GPKG="Data/NY_HUCS/NY_Cluster_Zones_250_NAomit_6347.gpkg"
OUTDIR="Data/Lidar/Metrics"
INDEX_DIR="Data/Lidar/Indexes"

# Cluster-to-index mapping (add entries as needed)
# Format: "cluster_number|index_gpkg_filename"
entries=(
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
    "225|USGS_2024.gpkg"
    "225|USGS_Clinton_Essex_Franklin_2014.gpkg"
    "67|USGS_Lake_Ontario_Hudson_River_2022.gpkg"
    "64|NYS_Erie_Genesee_Livingston_2019.gpkg"
    "64|NYS_Central_Finger_Lakes_2020.gpkg"
    "64|FEMA_2019.gpkg"
)

for entry in "${entries[@]}"; do
    cluster="${entry%%|*}"
    index_file="${entry##*|}"
    echo "Running lidar metrics for cluster $cluster using $index_file"
    srun --nodes=1 --ntasks=1 --exclusive \
        Rscript R_Code_Analysis/LIDAR_ftp.R \
            "$GPKG" \
            "$cluster" \
            "$INDEX_DIR/$index_file" \
            "$OUTDIR" >> "Shell_Scripts/logs/lidar_${cluster}_$(date +%Y%m%d).log" 2>&1 &
done

wait
echo "All lidar metric extractions completed."
