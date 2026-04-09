#!/bin/bash -l
#SBATCH --nodelist=cbsuxu05,cbsuxu06,cbsuxu07,cbsuxu08,cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem-per-cpu=16G
#SBATCH --cpus-per-task=5
#SBATCH --job-name=lidar
#SBATCH --ntasks=6
#SBATCH --ntasks-per-node=1
#SBATCH --time=24:00:00
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
    "250|NYS_Central_Finger_Lakes_2020.gpkg"
    "250|NYS_Great_Gully_2014.gpkg"
    "250|NYS_Cayuga_Oswego_2018.gpkg"
    "250|FEMA_Seneca_Watershed_2012.gpkg"
    "225|NYS_Warren_Washington_Essex_2015.gpkg"
    "225|FEMA_Fulton_Saratoga_Herkimer_Franklin_2017.gpkg"
    "225|USGS_2024.gpkg"
    "225|USGS_Clinton_Essex_Franklin_2014.gpkg"
    "218|County_Ontario_2006.gpkg"
    "218|NYS_Erie_Genesee_Livingston_2019.gpkg"
    "218|USDA_Livingston_2011.gpkg"
    "218|FEMA_2019.gpkg"
    "208|NYS_Central_Finger_Lakes_2020.gpkg"
    "208|County_Chemung_2005.gpkg"
    "208|County_Tompkins_2008.gpkg"
    "208|NYS_Cayuga_Oswego_2018.gpkg"
    "208|County_Cortland_2005.gpkg"
    "208|FEMA_2019.gpkg"
    "208|FEMA_Susquehanna_Basin_2007.gpkg"
    "168|NYS_Central_Finger_Lakes_2020.gpkg"
    "168|NYS_Cayuga_Oswego_2018.gpkg"
    "168|FEMA_Seneca_Watershed_2012.gpkg"
    "123|NYS_Warren_Washington_Essex_2015.gpkg"
    "123|FEMA_Hudson_Hoosic_2012.gpkg"
    "123|USGS_Lake_Ontario_Hudson_River_2022.gpkg"
    "123|USGS_2024.gpkg"
    "95|FEMA_Sullivan_2005_2007.gpkg"
    "95|FEMA_2019.gpkg"
    "95|NYS_Southeast_4_County_2022.gpkg"
    "95|USGS_3_County_2014.gpkg"
    "82|County_Niagara_2007.gpkg"
    "82|FEMA_Oneida_2008.gpkg"
    "82|NYS_Southwest_Fall_2017.gpkg"
    "82|NYS_Erie_Genesee_Livingston_2019.gpkg"
    "82|USDA_Genesee_2011.gpkg"
    "82|FEMA_2019.gpkg"
    "82|FEMA_Great_Lakes_2014.gpkg"
    "82|NYS_Lake_Ontario_Shoreline_2023.gpkg"
    "67|FEMA_Hudson_Hoosic_2012.gpkg"
    "67|USGS_Lake_Ontario_Hudson_River_2022.gpkg"
    "67|NYS_Rensselaer_Hoosick_River_2010.gpkg"
    "67|FEMA_2019.gpkg"
    "64|NYS_Central_Finger_Lakes_2020.gpkg"
    "64|County_Ontario_2006.gpkg"
    "64|NYS_Erie_Genesee_Livingston_2019.gpkg"
    "64|USDA_Livingston_2011.gpkg"
    "64|FEMA_2019.gpkg"
    "64|FEMA_Seneca_Watershed_2012.gpkg"
    "50|FEMA_Oneida_2008.gpkg"
    "50|NYS_Southwest_Fall_2017.gpkg"
    "50|NYS_Erie_Genesee_Livingston_2019.gpkg"
    "50|USDA_Genesee_2011.gpkg"
    "46|USGS_Clinton_Essex_Franklin_2014.gpkg"
    "22|FEMA_Franklin_St_Lawrence_2016_17.gpkg"
    "22|USGS_Clinton_Essex_Franklin_2014.gpkg"
    "11|FEMA_2019.gpkg"
    "11|FEMA_Franklin_St_Lawrence_2016_17.gpkg"
    "11|FEMA_Fulton_Saratoga_Herkimer_Franklin_2017.gpkg"
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
