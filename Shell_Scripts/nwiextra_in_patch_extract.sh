#!/bin/bash -l

# =============================================================================
# Build ADDITIONAL NWI-labelled patch vectors to double the training set.
#
# What it does:
#   Counts how many field/GIS-reviewed patches exist per HUC12 (distinct
#   PatchGroup across every file in R_Patches_Vector_Reviewed/ for that HUC),
#   then places that same number of NEW randomly located 256 x 256 m patches
#   inside the same HUC12 -- so the HUC's patch count doubles. Output is one
#   file per HUC12: R_Patches_Vector_NWIextra/NWIextra_cluster_<N>_huc_<ID>_256m.gpkg.
#
#   Placement rules: box centers are drawn only from vegetated NWI (PEM/PSS/PFO,
#   after the same reliability filters as nwi_in_patch_extract.sh) so every
#   patch actually contains wetland; boxes must lie entirely within the HUC12
#   (chips are cropped from per-HUC rasters, so a box poking out would fail);
#   and they may not overlap each other or ANY reviewed patch footprint
#   statewide, including ones from a neighbouring HUC's file that straddle the
#   boundary. Sampling retries up to 25 times and logs a shortfall if it cannot
#   place all n. Placement is seeded (set.seed(11)), so a full rebuild
#   reproduces the same boxes; a partial one does not.
#
#   The boxes are then labelled with the same NWI clip + MOD_CLASS scheme
#   (EMW / FSW / SSW / UPL) as the reviewed data, with ReviewerName "TBD" and
#   Confidence -999 since these are NWI delineations, not field-verified.
#
#   These patches COMPLEMENT the reviewed ones -- combine both folders at chip
#   generation to get the hybrid Field+GIS+NWI dataset. Distinct from
#   nwi_in_patch_extract.sh, which re-labels the SAME footprints with NWI.
#   HUC12s whose reviewed files all lack PatchGroup produce no output (no count).
#
#   Downstream, feed R_Patches_Vector_NWIextra/ to raster_chipspatches_dl.sh to
#   rasterize these vectors into R_Patches_NWIextra/.
#
# Usage:
#   bash Shell_Scripts/nwiextra_in_patch_extract.sh [REMOVE_EXISTING]
#
#   REMOVE_EXISTING  1/true to delete each already-written NWIextra_*.gpkg
#                    before regenerating it (positional $1, or the env var of
#                    the same name; the positional wins). Default 0 = resume,
#                    i.e. keep existing outputs and only create the missing ones.
#                    Use this after EDITING the reviewed vector data --
#                    otherwise the file.exists() guard in the R script skips
#                    every HUC already on disk, so a changed patch count or a
#                    moved reviewed footprint never takes effect. A HUC that
#                    drops out of the reviewed data entirely is never iterated
#                    over, so delete its NWIextra_* file by hand.
#                    Because placement shares one seeded RNG stream across HUCs
#                    in order, only a FULL rebuild reproduces prior boxes --
#                    a resume run draws different ones for the missing HUCs.
#                    Regenerating the vectors does NOT refresh the rasters:
#                    re-run raster_chipspatches_dl.sh with REMOVE_EXISTING=1
#                    afterwards.
#
# Examples:
#   bash Shell_Scripts/nwiextra_in_patch_extract.sh         # resume: fill in missing only
#   bash Shell_Scripts/nwiextra_in_patch_extract.sh 1       # force full, reproducible rebuild
#   REMOVE_EXISTING=1 bash Shell_Scripts/nwiextra_in_patch_extract.sh
#
# Slower than nwi_in_patch_extract.sh -- it inventories every reviewed file up
# front, then rejection-samples per HUC (tens of minutes; single process, no
# SLURM needed). Progress goes to Shell_Scripts/logs/nwiextra_patch_<date>.log,
# not the terminal; the log opens with the per-HUC reviewed patch inventory.
# =============================================================================

cd /ibstorage/anthony/NYS_Wetlands_Data

export TMPDIR=/ibstorage/anthony/tmp

module load R/4.4.3

# Positional $1 overrides the inherited env var. Exported so the Rscript sees it.
export REMOVE_EXISTING="${1:-${REMOVE_EXISTING:-0}}"
echo "REMOVE_EXISTING=${REMOVE_EXISTING}"

LOG="Shell_Scripts/logs/nwiextra_patch_$(date +%Y%m%d).log"
echo "Logging to ${LOG}"

Rscript R_Code_Analysis/NWIextra_Extract_From_Patches.R \
    "Data/NWI/NY_NWI_6347.gpkg" \
    "Data/Training_Data/R_Patches_Vector_NWIextra/" \
    "Data/Training_Data/R_Patches_Vector_Reviewed/" \
    "Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg" >> "$LOG" 2>&1 &

wait
echo "All Rscript executions completed."
