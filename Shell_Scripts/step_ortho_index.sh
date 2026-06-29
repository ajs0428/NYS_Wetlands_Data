#!/bin/bash -l
#SBATCH --partition=R256C128
#SBATCH --nodelist=cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=FAIL
#SBATCH --mem=8G
#SBATCH --job-name=ortho_index
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --output=Shell_Scripts/SLURM/slurm-ortho-index-%j.out

# =============================================================================
# ORTHO FOOTPRINT INDEX REBUILD -- single-task sbatch wrapper around
# gdaltindex_ortho.sh so the rebuild can sit in the SLURM dependency chain:
#
#   ortho download (step_ortho.sh) -> THIS -> ortho HUC (step_ortho_huc.sh)
#
# It rebuilds Data/Ortho/ortho_tiles.gpkg from scratch over Data/Ortho/Tiles/,
# so it must run exactly ONCE between the download and HUC stages (never in
# parallel with itself or with a download). step_combined_master.sh submits it
# with the right dependencies; it can also be run directly on a login node:
#   bash Shell_Scripts/gdaltindex_ortho.sh
# =============================================================================

cd /ibstorage/anthony/NYS_Wetlands_Data/

bash Shell_Scripts/gdaltindex_ortho.sh
