#!/bin/bash -l
#SBATCH --partition=R256C128
#SBATCH --nodelist=cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem-per-cpu=64G
#SBATCH --job-name=ortho
#SBATCH --cpus-per-task=1
#SBATCH --ntasks=5
#SBATCH --output=Shell_Scripts/SLURM/slurm-ortho-%j.out

# =============================================================================
# ORTHO DOWNLOAD -- clusters passed on the command line.
#
#   Usage:  sbatch step_ortho.sh "<comma-sep clusters>" [year] [bands]
#   Single cluster:   sbatch step_ortho.sh "208" 2023 4bd
#   Several clusters: sbatch step_ortho.sh "208,225,11" 2023 4bd
#   year/bands default to ORTHO_YEAR / ORTHO_BANDS from batch_config.sh, so
#   step_combined_master.sh can call this with just the cluster list.
#
#   `year` is the PREFERRED year: Ortho_ftp.R takes that year's tiles first
#   and, where the cluster is not covered (no coverage for the year, or a
#   collection boundary), fills the gap with the nearest other year(s).
#
# NO `conda activate` is needed: the ORTHO_GDALWARP wrapper activates the conda
# 'ortho' env inside its own subprocess for the JP2 decode/reproject only. This
# job just needs `module load R`. mem is lighter than the other steps because
# that gdalwarp streams the warp outside of R.
# =============================================================================

cd /ibstorage/anthony/NYS_Wetlands_Data/
export TMPDIR=/ibstorage/anthony/NYS_Wetlands_Data/Data/tmp/
module load R/4.4.3

source Shell_Scripts/batch_config.sh   # GPKG, ORTHO_YEAR, ORTHO_BANDS

# JP2-capable gdalwarp wrapper (activates conda 'ortho' only for the subprocess,
# keeping conda's GDAL_DATA/PROJ_LIB out of R's terra/sf).
export ORTHO_GDALWARP="$PWD/Shell_Scripts/ortho_gdalwarp.sh"

IFS=',' read -ra include <<< "$1"
YEAR="${2:-$ORTHO_YEAR}"
BANDS="${3:-$ORTHO_BANDS}"
OUTDIR="Data/Ortho/Tiles"
DATE=$(date +%Y%m%d)

unset SLURM_MEM_PER_CPU SLURM_MEM_PER_NODE SLURM_MEM_PER_GPU

echo "=== Ortho download (year $YEAR, $BANDS) ==="
# Track each srun's PID -> cluster so a failed Rscript is reported. A bare
# `wait` returns 0 regardless, which made a failed cluster look like success.
declare -A PID_CLUSTER=()
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
    PID_CLUSTER[$!]=$number
done

FAILED=()
for pid in "${!PID_CLUSTER[@]}"; do
    if ! wait "$pid"; then
        number=${PID_CLUSTER[$pid]}
        echo "FAILED: cluster $number (see Shell_Scripts/logs/ortho_${number}_${YEAR}_${DATE}.log)"
        FAILED+=("$number")
    fi
done

if [[ ${#FAILED[@]} -gt 0 ]]; then
    # Not exit 1: ortho_index depends on this stage with afterok in step_combined_master.sh,
    # and ortho_huc on ortho_index; a non-zero exit would cancel the whole ortho
    # branch over one bad cluster. The index rebuild just reflects the tiles on
    # disk, so report loudly and exit 0.
    echo "ortho finished with ${#FAILED[@]} failed cluster(s): ${FAILED[*]}"
    echo "(exiting 0 so downstream stages still run for the other clusters)"
    exit 0
fi
echo "Ortho download completed."
