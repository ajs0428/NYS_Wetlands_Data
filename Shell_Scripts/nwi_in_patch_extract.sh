#!/bin/bash -l

# =============================================================================
# Build NWI-labelled patch VECTORS that mirror the field/GIS-reviewed patches.
#
# What it does:
#   For every reviewed patch file in R_Patches_Vector_Reviewed/, dissolve its
#   patches back into one 256 x 256 m box per PatchGroup, clip the National
#   Wetlands Inventory to those boxes, and write the result as
#   NWI_<same filename>.gpkg in R_Patches_Vector_NWI/. The NWI is filtered to
#   the reliable classes first (drops riverine R1-R5, lakes > 20 ha, and
#   marine/estuarine/other), then everything inside a box that is NOT wetland
#   is emitted as UPL, so each box is fully tiled. Classes are collapsed to the
#   modelling schema MOD_CLASS (EMW / FSW / SSW / UPL) exactly as the reviewed
#   data uses, and PatchGroup is carried over so NWI patches line up 1:1 with
#   the reviewed patches. Review provenance is deliberately NOT copied --
#   ReviewerName is reset to "TBD" and Confidence to -999, because these are
#   NWI delineations, not field-verified ones.
#
#   The output is the ALTERNATIVE label set for the same footprints (reviewed
#   vs. NWI truth over identical patches), not additional patches. For extra
#   patches placed elsewhere in the HUC, see nwiextra_in_patch_extract.sh.
#
#   Reviewed files with no PatchGroup column are skipped (they can't be split
#   per patch). Downstream, feed R_Patches_Vector_NWI/ to
#   raster_chipspatches_dl.sh to rasterize these vectors into R_Patches_NWI/.
#
# Usage:
#   bash Shell_Scripts/nwi_in_patch_extract.sh [REMOVE_EXISTING]
#
#   REMOVE_EXISTING  1/true to delete each already-written NWI_*.gpkg before
#                    regenerating it (positional $1, or the env var of the same
#                    name; the positional wins). Default 0 = resume, i.e. keep
#                    existing outputs and only create the missing ones.
#                    Use this after EDITING the reviewed vector data --
#                    otherwise the file.exists() guard in the R script skips
#                    every NWI file already on disk and the edits never reach
#                    them. A reviewed file deleted outright is never iterated
#                    over, so delete its NWI_* counterpart by hand.
#                    Regenerating the vectors does NOT refresh the rasters:
#                    re-run raster_chipspatches_dl.sh with REMOVE_EXISTING=1
#                    afterwards.
#
# Examples:
#   bash Shell_Scripts/nwi_in_patch_extract.sh              # resume: fill in missing only
#   bash Shell_Scripts/nwi_in_patch_extract.sh 1            # force full rebuild
#   REMOVE_EXISTING=1 bash Shell_Scripts/nwi_in_patch_extract.sh
#
# Runtime is a few minutes over ~70 files (single process, no SLURM needed).
# Progress goes to Shell_Scripts/logs/nwi_patch_<date>.log, not the terminal.
# =============================================================================

cd /ibstorage/anthony/NYS_Wetlands_Data

export TMPDIR=/ibstorage/anthony/tmp

module load R/4.4.3

# Positional $1 overrides the inherited env var. Exported so the Rscript sees it.
export REMOVE_EXISTING="${1:-${REMOVE_EXISTING:-0}}"
echo "REMOVE_EXISTING=${REMOVE_EXISTING}"

LOG="Shell_Scripts/logs/nwi_patch_$(date +%Y%m%d).log"
echo "Logging to ${LOG}"

Rscript R_Code_Analysis/NWI_Extract_From_Patches.R \
    "Data/NWI/NY_NWI_6347.gpkg" \
    "Data/Training_Data/R_Patches_Vector_NWI/" \
    "Data/Training_Data/R_Patches_Vector_Reviewed/" >> "$LOG" 2>&1 &

wait
echo "All Rscript executions completed."
