#!/bin/bash -l
#SBATCH --nodelist=cbsuxu06,cbsuxu07,cbsuxu08,cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem-per-cpu=8G
#SBATCH --cpus-per-task=8
#SBATCH --job-name=ortho
#SBATCH --ntasks=5
#SBATCH --ntasks-per-node=1
#SBATCH --time=24:00:00
#SBATCH --output=Shell_Scripts/SLURM/slurm-ortho-%j.out

# =============================================================================
# ORTHO DOWNLOAD -- standalone version (cluster list hardcoded in this file)
#
#   Usage:  sbatch Shell_Scripts/ortho_loop.sh        (takes NO arguments)
#   Set the imagery year at `YEAR=` below; it applies to all clusters.
#   The 14-cluster list is hardcoded at `clusters=( ... )` below -- edit there.
#
# For a single cluster, or to pass the year/clusters on the command line, use
# step_ortho.sh instead:  sbatch step_ortho.sh "208" 2023 4bd
#
# NO `conda activate` is needed: the ORTHO_GDALWARP wrapper activates the conda
# 'ortho' env inside its own subprocess for the JP2 decode/reproject only. This
# job just needs `module load R`.
# =============================================================================
cd /ibstorage/anthony/NYS_Wetlands_Data/

export TMPDIR=/ibstorage/anthony/NYS_Wetlands_Data/Data/tmp/

module load R/4.4.3

# Point Ortho_ftp.R at the JP2-capable gdalwarp wrapper (full path). The wrapper
# activates the conda 'ortho' env only for the gdalwarp subprocess, so R/terra
# are not affected by conda's GDAL_DATA/PROJ_LIB.
export ORTHO_GDALWARP="$PWD/Shell_Scripts/ortho_gdalwarp.sh"

mkdir -p Shell_Scripts/SLURM Shell_Scripts/logs

GPKG="Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg"
OUTDIR="Data/Ortho/Tiles"
YEAR=2020          # imagery year applied to every cluster (edit as needed)
BANDS=4bd

# Same cluster set as lidar_loop.sh
clusters=(11 22 46 50 64 67 82 95 123 168 208 218 225 250)

for cluster in "${clusters[@]}"; do
    echo "Running ortho download for cluster $cluster (year $YEAR, $BANDS)"
    srun --nodes=1 --ntasks=1 --exclusive \
        Rscript R_Code_Analysis/Ortho_ftp.R \
            "$GPKG" \
            "$cluster" \
            "$YEAR" \
            "$OUTDIR" \
            "$BANDS" >> "Shell_Scripts/logs/ortho_${cluster}_${YEAR}_$(date +%Y%m%d).log" 2>&1 &
done

wait
echo "All ortho downloads completed."
