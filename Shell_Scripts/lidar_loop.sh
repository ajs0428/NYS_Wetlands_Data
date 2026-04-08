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
    "123|NYS_Warren_Washington_Essex_2015.gpkg"
    "138|NYS_Warren_Washington_Essex_2015.gpkg"
    "152|NYS_Warren_Washington_Essex_2015.gpkg"
    "183|NYS_Warren_Washington_Essex_2015.gpkg"
    "192|NYS_Warren_Washington_Essex_2015.gpkg"
    "225|NYS_Warren_Washington_Essex_2015.gpkg"
    "64|NYS_Central_Finger_Lakes_2020.gpkg"
    "84|NYS_Central_Finger_Lakes_2020.gpkg"
    "90|NYS_Central_Finger_Lakes_2020.gpkg"
    "208|NYS_Central_Finger_Lakes_2020.gpkg"
    "250|NYS_Central_Finger_Lakes_2020.gpkg"
    "84|FEMA_Chemung_Watershed_2011.gpkg"
    "56|USGS_North_East_2011.gpkg"
    "86|USGS_North_East_2011.gpkg"
    "92|USGS_North_East_2011.gpkg"
    "116|USGS_North_East_2011.gpkg"
    "67|FEMA_Hudson_Hoosic_2012.gpkg"
    "123|FEMA_Hudson_Hoosic_2012.gpkg"
    "136|FEMA_Hudson_Hoosic_2012.gpkg"
    "192|FEMA_Hudson_Hoosic_2012.gpkg"
    "67|USGS_Lake_Ontario_Hudson_River_2022.gpkg"
    "120|USGS_Lake_Ontario_Hudson_River_2022.gpkg"
    "123|USGS_Lake_Ontario_Hudson_River_2022.gpkg"
    "136|USGS_Lake_Ontario_Hudson_River_2022.gpkg"
    "192|USGS_Lake_Ontario_Hudson_River_2022.gpkg"
    "250|NYS_Great_Gully_2014.gpkg"
    "67|NYS_Rensselaer_Hoosick_River_2010.gpkg"
    "136|NYS_Rensselaer_Hoosick_River_2010.gpkg"
    "120|NYS_Greene_East_Half_2010.gpkg"
    "120|NYS_Columbia_Rensselaer_2016.gpkg"
    "136|NYS_Columbia_Rensselaer_2016.gpkg"
    "50|NYS_Southwest_Fall_2017.gpkg"
    "90|NYS_Cayuga_Oswego_2018.gpkg"
    "208|NYS_Cayuga_Oswego_2018.gpkg"
    "250|NYS_Cayuga_Oswego_2018.gpkg"
    "53|NYS_Madison_Otsego_2015.gpkg"
    "105|NYS_Madison_Otsego_2015.gpkg"
    "176|NYS_Madison_Otsego_2015.gpkg"
    "189|NYS_Madison_Otsego_2015.gpkg"
    "193|NYS_Madison_Otsego_2015.gpkg"
    "50|NYS_Erie_Genesee_Livingston_2019.gpkg"
    "64|NYS_Erie_Genesee_Livingston_2019.gpkg"
    "218|NYS_Erie_Genesee_Livingston_2019.gpkg"
    "50|USDA_Genesee_2011.gpkg"
    "64|USDA_Livingston_2011.gpkg"
    "218|USDA_Livingston_2011.gpkg"
    "84|NYS_Allegany_Steuben_2016.gpkg"
    "11|FEMA_2019.gpkg"
    "11|FEMA_Franklin_St_Lawrence_2016_17.gpkg"
    "11|FEMA_Fulton_Saratoga_Herkimer_Franklin_2017.gpkg"
    "12|USGS_Clinton_Essex_Franklin_2014.gpkg"
    "22|FEMA_Franklin_St_Lawrence_2016_17.gpkg"
    "22|USGS_Clinton_Essex_Franklin_2014.gpkg"
    "46|USGS_Clinton_Essex_Franklin_2014.gpkg"
    "51|FEMA_Franklin_St_Lawrence_2016_17.gpkg"
    "51|FEMA_Fulton_Saratoga_Herkimer_Franklin_2017.gpkg"
    "51|USGS_Clinton_Essex_Franklin_2014.gpkg"
    "53|FEMA_2019.gpkg"
    "56|FEMA_2019.gpkg"
    "56|NYS_Southeast_4_County_2022.gpkg"
    "60|FEMA_2019.gpkg"
    "60|FEMA_Franklin_St_Lawrence_2016_17.gpkg"
    "60|FEMA_Fulton_Saratoga_Herkimer_Franklin_2017.gpkg"
    "64|FEMA_2019.gpkg"
    "64|FEMA_Seneca_Watershed_2012.gpkg"
    "67|FEMA_2019.gpkg"
    "84|FEMA_2019.gpkg"
    "84|FEMA_Seneca_Watershed_2012.gpkg"
    "86|FEMA_2019.gpkg"
    "86|NYS_Southeast_4_County_2022.gpkg"
    "86|USGS_3_County_2014.gpkg"
    "90|FEMA_2019.gpkg"
    "90|FEMA_Seneca_Watershed_2012.gpkg"
    "92|FEMA_2019.gpkg"
    "92|NYS_Southeast_4_County_2022.gpkg"
    "92|USGS_3_County_2014.gpkg"
    "102|FEMA_2019.gpkg"
    "102|FEMA_Fulton_Saratoga_Herkimer_Franklin_2017.gpkg"
    "102|FEMA_Oneida_Subbasin_2016_17.gpkg"
    "105|FEMA_2019.gpkg"
    "116|NYS_Southeast_4_County_2022.gpkg"
    "116|USGS_3_County_2014.gpkg"
    "120|FEMA_2019.gpkg"
    "123|USGS_2024.gpkg"
    "126|FEMA_Franklin_St_Lawrence_2016_17.gpkg"
    "136|FEMA_2019.gpkg"
    "138|FEMA_2019.gpkg"
    "138|USGS_2024.gpkg"
    "138|USGS_Clinton_Essex_Franklin_2014.gpkg"
    "152|USGS_2024.gpkg"
    "152|USGS_Clinton_Essex_Franklin_2014.gpkg"
    "176|FEMA_2019.gpkg"
    "176|FEMA_Oneida_Subbasin_2016_17.gpkg"
    "183|FEMA_Franklin_St_Lawrence_2016_17.gpkg"
    "183|FEMA_Fulton_Saratoga_Herkimer_Franklin_2017.gpkg"
    "183|USGS_2024.gpkg"
    "183|USGS_Clinton_Essex_Franklin_2014.gpkg"
    "187|FEMA_Franklin_St_Lawrence_2016_17.gpkg"
    "189|FEMA_2019.gpkg"
    "192|FEMA_Fulton_Saratoga_Herkimer_Franklin_2017.gpkg"
    "192|USGS_2024.gpkg"
    "193|FEMA_2019.gpkg"
    "193|FEMA_Oneida_Subbasin_2016_17.gpkg"
    "198|USGS_Clinton_Essex_Franklin_2014.gpkg"
    "203|FEMA_Franklin_St_Lawrence_2016_17.gpkg"
    "208|FEMA_2019.gpkg"
    "218|FEMA_2019.gpkg"
    "225|FEMA_Fulton_Saratoga_Herkimer_Franklin_2017.gpkg"
    "225|USGS_2024.gpkg"
    "225|USGS_Clinton_Essex_Franklin_2014.gpkg"
    "240|FEMA_Franklin_St_Lawrence_2016_17.gpkg"
    "250|FEMA_Seneca_Watershed_2012.gpkg"
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
