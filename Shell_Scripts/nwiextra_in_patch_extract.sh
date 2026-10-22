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
# Presets (positional $2, default x1):
#   x1   the original set above: 1x reviewed count per HUC, seed 11, one RNG
#        stream -> R_Patches_Vector_NWIextra/NWIextra_*.gpkg (unchanged).
#   x10  the 10x NWI quantity arm: 8x each HUC's R_Patches raster count of NEW
#        boxes (1,126 x 8 = 9,008) -> R_Patches_Vector_NWIextra10/NWIextra10_*.gpkg.
#        8x, not 10x, because the arm's pool is R_Patches_NWI (1x, paired) U
#        R_Patches_NWIextra (1x) U R_Patches_NWIextra10 (8x) = 10x, nesting
#        nwi < nwiextra < nwiextra10. Boxes also avoid every
#        R_Patches_Vector_NWIextra/ footprint and keep a 2 m clearance (so
#        rasterized windows can't share a pixel). Most reviewed HUCs can't hold
#        8x, so SPILL mode places each shortfall in stack-ready HUCs (full
#        factorial suite incl. lidar + leaf-off; list made here by
#        check_stack_ready.sh all) -- same cluster first, then nearest anywhere,
#        never in a reviewed HUC. All-or-nothing: a rerun needs REMOVE_EXISTING=1.
#        Writes NWIextra10_spill_manifest.csv (target HUC <- source HUC). Needs
#        the 1x set on disk first. Rasterize with raster_chipspatches_dl.sh
#        Data/Training_Data/R_Patches_Vector_NWIextra10/ -> R_Patches_NWIextra10/.
#   Any of MULTIPLIER, FILE_PREFIX, AVOID_DIRS, MIN_GAP, SEED, PER_HUC_SEED,
#   MAX_ITER, SPILL, COUNT_DIR, READY_PAIRS, STALL_LIMIT set in the environment
#   override the preset; ONLY_HUCS=<id,id>
#   restricts the run to those HUC12s (for testing). See the R script header.
#
# Usage:
#   bash Shell_Scripts/nwiextra_in_patch_extract.sh [REMOVE_EXISTING] [PRESET]
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
#   bash Shell_Scripts/nwiextra_in_patch_extract.sh 1 x10   # 10x arm (full rebuild)
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

PRESET="${2:-x1}"
case "$PRESET" in
    x1)
        OUT_DIR="Data/Training_Data/R_Patches_Vector_NWIextra/"
        ;;
    x10)
        OUT_DIR="Data/Training_Data/R_Patches_Vector_NWIextra10/"
        export MULTIPLIER="${MULTIPLIER:-8}"
        export FILE_PREFIX="${FILE_PREFIX:-NWIextra10}"
        export AVOID_DIRS="${AVOID_DIRS:-Data/Training_Data/R_Patches_Vector_NWIextra/}"
        export MIN_GAP="${MIN_GAP:-2}"
        export SEED="${SEED:-1010}"
        export PER_HUC_SEED="${PER_HUC_SEED:-0}"
        export MAX_ITER="${MAX_ITER:-100}"
        export STALL_LIMIT="${STALL_LIMIT:-10}"
        export SPILL="${SPILL:-1}"
        export COUNT_DIR="${COUNT_DIR:-Data/Training_Data/R_Patches/}"
        if [ -z "${READY_PAIRS:-}" ]; then
            READY_OUT="Shell_Scripts/logs/nwiextra10_stack_ready_$(date +%Y%m%d).txt"
            # Exits 1 whenever ANY HUC is not ready (always true statewide), so
            # judge success by the pairs file instead of the exit code.
            bash Shell_Scripts/check_stack_ready.sh all -o "${READY_OUT}" > /dev/null
            READY_PAIRS="${READY_OUT%.txt}_valid_pairs.txt"
            [ -s "${READY_PAIRS}" ] || { echo "No stack-ready pairs in ${READY_PAIRS}" >&2; exit 1; }
        fi
        export READY_PAIRS
        ;;
    *)
        echo "Unknown preset '${PRESET}' (expected x1 or x10)" >&2
        exit 1
        ;;
esac
echo "PRESET=${PRESET} -> ${OUT_DIR}"

LOG="Shell_Scripts/logs/nwiextra_patch_${PRESET}_$(date +%Y%m%d).log"
echo "Logging to ${LOG}"

Rscript R_Code_Analysis/NWIextra_Extract_From_Patches.R \
    "Data/NWI/NY_NWI_6347.gpkg" \
    "${OUT_DIR}" \
    "Data/Training_Data/R_Patches_Vector_Reviewed/" \
    "Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg" >> "$LOG" 2>&1 &

wait
echo "All Rscript executions completed."
