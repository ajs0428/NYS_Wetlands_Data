#!/bin/bash -l
#SBATCH --nodelist=cbsuxu06,cbsuxu07,cbsuxu08,cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem-per-cpu=64G
#SBATCH --job-name=ortho_huc
#SBATCH --ntasks=5
#SBATCH --cpus-per-task=1
#SBATCH --ntasks-per-node=1
#SBATCH --output=Shell_Scripts/SLURM/slurm-ortho-huc-%j.out

# =============================================================================
# ORTHO -> HUC12  (mosaic overlapping ortho tiles, crop/mask to each HUC12,
# resample onto that HUC12's DEM so the ortho aligns with the terrain stack).
#
# PREREQUISITES (run once after the ortho DOWNLOAD batch finishes):
#   1. Ortho_ftp.R has written tiles to Data/Ortho/Tiles/ (see step_ortho.sh).
#   2. The HUC DEMs exist at Data/TerrainProcessed/HUC_DEMs/cluster_*_huc_*.tif
#      (from DEM_Extract_singleVect_CMD.R / step_dem.sh).
#   3. Rebuild the tile footprint index:  bash Shell_Scripts/gdaltindex_ortho.sh
#
#   Usage:  sbatch step_ortho_huc.sh "<comma-sep clusters>" [year]
#   Single cluster:   sbatch step_ortho_huc.sh "208" 2023
#   Several clusters: sbatch step_ortho_huc.sh "208,225,11" 2023
#   `year` (default 2020) is the PREFERRED year: each HUC12 uses that year where
#   it has coverage and only fills gaps with the nearest other year(s), so HUCs
#   stay single-year where possible (years used are logged + written to the
#   GeoTIFF metadata). To process ONE HUC12 of one cluster, call the R script
#   directly with a 7th arg (the huc12 code) instead of using this loop.
# =============================================================================

cd /ibstorage/anthony/NYS_Wetlands_Data/
export TMPDIR=/ibstorage/anthony/NYS_Wetlands_Data/Data/tmp/
module load R/4.4.3

IFS=',' read -ra include <<< "$1"
YEAR="${2:-2020}"
GPKG="Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg"
ORTHO_INDEX="Data/Ortho/ortho_tiles.gpkg"
DEM_DIR="Data/TerrainProcessed/HUC_DEMs"
OUTDIR="Data/Ortho/HUC_Ortho/"
DATE=$(date +%Y%m%d)

mkdir -p "$OUTDIR" Shell_Scripts/SLURM Shell_Scripts/logs
unset SLURM_MEM_PER_CPU SLURM_MEM_PER_NODE SLURM_MEM_PER_GPU

echo "=== Ortho -> HUC12 (year $YEAR) ==="
for number in "${include[@]}"; do
    echo "  Cluster $number – ortho/HUC"
    srun --nodes=1 --ntasks=1 --exclusive \
        Rscript R_Code_Analysis/Ortho_HUC_Processing.R \
        "$GPKG" \
        "$number" \
        "$YEAR" \
        "$ORTHO_INDEX" \
        "$DEM_DIR" \
        "$OUTDIR" \
        >> "Shell_Scripts/logs/ortho_huc_${number}_${YEAR}_${DATE}.log" 2>&1 &
done

wait
echo "Ortho -> HUC12 processing completed."
