#!/bin/bash -l
#SBATCH --nodelist=cbsuxu06,cbsuxu07,cbsuxu08,cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem-per-cpu=16G
#SBATCH --job-name=ortho
#SBATCH --cpus-per-task=1
#SBATCH --ntasks=5
#SBATCH --ntasks-per-node=1
#SBATCH --output=Shell_Scripts/SLURM/slurm-ortho-%j.out

# =============================================================================
# ORTHO DOWNLOAD -- argument-driven version (clusters passed on the command line)
#
#   Usage:  sbatch step_ortho.sh "<comma-sep clusters>" [year] [bands]
#   Single cluster:   sbatch step_ortho.sh "208" 2023 4bd
#   Several clusters: sbatch step_ortho.sh "208,225,11" 2023 4bd
#   year/bands are optional and default to 2020 / 4bd, so step_combined_master.sh
#   can call this with just the cluster list.
#
# For the full standing set of 14 clusters with the year hardcoded inside the
# file (no arguments), use ortho_loop.sh instead.
#
# NO `conda activate` is needed: the ORTHO_GDALWARP wrapper activates the conda
# 'ortho' env inside its own subprocess for the JP2 decode/reproject only. This
# job just needs `module load R`. mem is lighter than the other steps because
# that gdalwarp streams the warp outside of R.
# =============================================================================

cd /ibstorage/anthony/NYS_Wetlands_Data/
export TMPDIR=/ibstorage/anthony/NYS_Wetlands_Data/Data/tmp/
module load R/4.4.3

# JP2-capable gdalwarp wrapper (activates conda 'ortho' only for the subprocess,
# keeping conda's GDAL_DATA/PROJ_LIB out of R's terra/sf).
export ORTHO_GDALWARP="$PWD/Shell_Scripts/ortho_gdalwarp.sh"

IFS=',' read -ra include <<< "$1"
YEAR="${2:-2020}"
BANDS="${3:-4bd}"
GPKG="Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg"
OUTDIR="Data/Ortho/Tiles"
DATE=$(date +%Y%m%d)

unset SLURM_MEM_PER_CPU SLURM_MEM_PER_NODE SLURM_MEM_PER_GPU

echo "=== Ortho download (year $YEAR, $BANDS) ==="
for number in "${include[@]}"; do
    echo "  Cluster $number – ortho"
    srun --nodes=1 --ntasks=1 --exclusive \
        Rscript R_Code_Analysis/Ortho_ftp.R \
        "$GPKG" \
        "$number" \
        "$YEAR" \
        "$OUTDIR" \
        "$BANDS" \
        >> "Shell_Scripts/logs/ortho_${number}_${YEAR}_${DATE}.log" 2>&1 &
done

wait
echo "Ortho download completed."
