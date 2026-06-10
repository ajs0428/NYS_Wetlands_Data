#!/bin/bash
# =============================================================================
# Master script -- submits one SLURM job per processing step with the full
# dependency graph, for a set of HUC12 clusters.
#
#   Usage:  bash step_combined_master.sh <clusters>
#           <clusters> is either a comma-separated list ("225" or "208,225,11")
#           or a batch name from batch_config.sh ("batch1").
#
#   Examples:
#     bash step_combined_master.sh 225
#     bash step_combined_master.sh batch1
#     DRYRUN=1 bash step_combined_master.sh batch1   # print sbatch graph only
#
#   Optional environment flags:
#     DRYRUN=1          print the sbatch commands instead of submitting
#     SKIP_LIDAR_FTP=1  skip the lidar tile download/metrics stage (tiles in
#                       Data/Lidar/Metrics already cover these clusters)
#     SKIP_ORTHO_DL=1   skip the ortho tile download stage (tiles in
#                       Data/Ortho/Tiles already cover these clusters); the
#                       footprint index is still rebuilt
#
# Dependency graph (afterok unless noted):
#
#   dem ──┬── terrain slp
#         ├── hydro
#         ├── chm            (CHM resamples onto the HUC DEM)
#         ├── naip           (NAIP resamples onto the HUC DEM)
#         └────────────────────────┐
#   lidar_ftp ── lidar_huc         │
#   ortho_dl ─── ortho_index ── ortho_huc   (needs index AND dem)
#         (everything) ── check    (afterany; missing-output report)
#
# Satellite (sat_gee) and terrain curv/dmv were removed 2026-06: their outputs
# are not in the huc_stack.R band contract. step_terrain.sh still accepts
# curv/dmv as a manual one-off if ever needed.
#
# MANUAL PREREQUISITES (once per data refresh, not per run):
#   - DEM source tiles for these clusters exist in Data/DEMs/ (no automated
#     DEM download exists; DEM_Extract reads Data/DEMs/NYS_All_DEM_Index.gpkg)
#   - Lidar collection indexes are current: Rscript download_lidar_indexes.R
#     then Rscript build_lidar_index.R (refreshes NYS_Lidar_All_Indexes.gpkg)
# =============================================================================

cd /ibstorage/anthony/NYS_Wetlands_Data/ 2>/dev/null || true

module load R/4.4.3

source Shell_Scripts/batch_config.sh
SCRIPTDIR="Shell_Scripts"

# ── Resolve cluster selection from $1 ────────────────────────────────────────
if [[ -z "${1:-}" ]]; then
    echo "Usage: bash $0 <clusters>"
    echo "  <clusters> = comma-separated cluster numbers (e.g. \"208,225\")"
    echo "               or a batch name from batch_config.sh (e.g. \"batch1\")"
    exit 1
fi

if [[ "$1" =~ ^batch[0-9]+$ ]]; then
    ref="$1[@]"
    include=("${!ref}")
    if [[ ${#include[@]} -eq 0 ]]; then
        echo "ERROR: '$1' is not defined in batch_config.sh"; exit 1
    fi
else
    IFS=',' read -ra include <<< "$1"
fi

INCLUDE_STR=$(IFS=,; echo "${include[*]}")
echo "Clusters: $INCLUDE_STR"
echo "Ortho year: $ORTHO_YEAR ($ORTHO_BANDS)"

mkdir -p "$LOGDIR" "$SCRIPTDIR/SLURM"

# ── Submission helper (DRYRUN=1 prints instead of submitting) ───────────────
submit() {  # submit <dependency-or-""> <script> [args...]
    local dep="$1"; shift
    local flags=(--parsable)
    [[ -n "$dep" ]] && flags+=("--dependency=$dep")
    if [[ "${DRYRUN:-0}" == "1" ]]; then
        echo "DRYRUN: sbatch ${flags[*]} $*" >&2
        # Fake job id named after the script so the printed dependency
        # strings stay readable (runs in a subshell; a counter won't stick).
        echo "dry_$(basename "$1" .sh)"
    else
        sbatch "${flags[@]}" "$@"
    fi
}

# ── DEM (root of the terrain-aligned steps) ─────────────────────────────────
echo "Submitting DEM extraction..."
jid_dem=$(submit "" "$SCRIPTDIR/step_dem.sh" "$INCLUDE_STR")
echo "  Job $jid_dem"

echo "Submitting terrain slope/geomorphons (after DEM)..."
jid_slp=$(submit "afterok:$jid_dem" "$SCRIPTDIR/step_terrain.sh" "$INCLUDE_STR" slp)
echo "  Job $jid_slp"

echo "Submitting hydro (after DEM)..."
jid_hydro=$(submit "afterok:$jid_dem" "$SCRIPTDIR/step_hydro.sh" "$INCLUDE_STR")
echo "  Job $jid_hydro"

# CHM and NAIP both resample onto Data/TerrainProcessed/HUC_DEMs/, so they
# must wait for DEM (CHM silently skips HUCs whose DEM is missing).
echo "Submitting CHM extraction (after DEM)..."
jid_chm=$(submit "afterok:$jid_dem" "$SCRIPTDIR/step_chm.sh" "$INCLUDE_STR")
echo "  Job $jid_chm"

echo "Submitting NAIP processing (after DEM)..."
jid_naip=$(submit "afterok:$jid_dem" "$SCRIPTDIR/step_naip.sh" "$INCLUDE_STR")
echo "  Job $jid_naip"

# ── Lidar: tile download+metrics, then HUC merge ─────────────────────────────
if [[ "${SKIP_LIDAR_FTP:-0}" == "1" ]]; then
    echo "Skipping lidar FTP stage (SKIP_LIDAR_FTP=1)..."
    lidar_dep=""
else
    echo "Submitting lidar tile download + metrics..."
    jid_lftp=$(submit "" "$SCRIPTDIR/step_lidar_ftp.sh" "$INCLUDE_STR")
    echo "  Job $jid_lftp"
    lidar_dep="afterok:$jid_lftp"
fi

echo "Submitting lidar HUC merge${lidar_dep:+ (after lidar FTP)}..."
jid_lidar=$(submit "$lidar_dep" "$SCRIPTDIR/step_lidar.sh" "$INCLUDE_STR")
echo "  Job $jid_lidar"

# ── Ortho: tile download, footprint index rebuild, then HUC compositing ──────
if [[ "${SKIP_ORTHO_DL:-0}" == "1" ]]; then
    echo "Skipping ortho download stage (SKIP_ORTHO_DL=1)..."
    oidx_dep=""
else
    echo "Submitting ortho tile download..."
    jid_odl=$(submit "" "$SCRIPTDIR/step_ortho.sh" "$INCLUDE_STR" "$ORTHO_YEAR" "$ORTHO_BANDS")
    echo "  Job $jid_odl"
    oidx_dep="afterok:$jid_odl"
fi

# Index rebuild always runs: it is cheap and must reflect the tiles on disk
# before the HUC step reads it. Single job -- it rebuilds the shared gpkg.
echo "Submitting ortho footprint index rebuild${oidx_dep:+ (after ortho download)}..."
jid_oidx=$(submit "$oidx_dep" "$SCRIPTDIR/step_ortho_index.sh")
echo "  Job $jid_oidx"

echo "Submitting ortho -> HUC compositing (after index + DEM)..."
jid_ohuc=$(submit "afterok:$jid_oidx:$jid_dem" "$SCRIPTDIR/step_ortho_huc.sh" "$INCLUDE_STR" "$ORTHO_YEAR")
echo "  Job $jid_ohuc"

# ── Final check: report missing per-HUC outputs across all 7 source dirs ─────
echo "Submitting pipeline output check (after everything)..."
jid_check=$(submit "afterany:$jid_slp:$jid_hydro:$jid_chm:$jid_naip:$jid_lidar:$jid_ohuc" \
    "$SCRIPTDIR/step_check.sh" "$INCLUDE_STR")
echo "  Job $jid_check"

echo ""
echo "All jobs submitted."
echo "Monitor with: squeue -u \$USER"
echo "Output check report will land in $LOGDIR/pipeline_check_*.log"
