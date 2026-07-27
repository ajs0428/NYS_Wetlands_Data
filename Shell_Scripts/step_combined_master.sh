#!/bin/bash
# =============================================================================
# Master script -- submits one SLURM job per processing step with the full
# dependency graph, for a set of HUC12 clusters.
#
#   Usage:  bash step_combined_master.sh <clusters> [step]
#           <clusters> is either a comma-separated list ("225" or "208,225,11")
#           or a batch name from batch_config.sh ("batch1").
#           [step] (optional) runs only that one stage instead of the full graph.
#             Valid steps: dem slp hydro chm naip lidar_ftp lidar
#                          ortho_dl ortho_index ortho_huc check
#           Before submitting a single step, its upstream outputs are checked on
#           disk for the requested clusters; if any are missing the run aborts
#           with the step to run first (no SLURM dependency chaining is done).
#
#   Examples:
#     bash step_combined_master.sh 225
#     bash step_combined_master.sh batch1
#     bash step_combined_master.sh batch2 hydro       # one stage only
#     DRYRUN=1 bash step_combined_master.sh batch1    # print sbatch graph only
#     DRYRUN=1 bash step_combined_master.sh batch2 hydro
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
#   dem ──┬── terrain slp   (slope/TPI/geomorphons/meanc/dmv, one file)
#         ├── hydro
#         ├── chm            (CHM resamples onto the HUC DEM)
#         ├── naip           (NAIP resamples onto the HUC DEM)
#         └────────────────────────┐
#   lidar_ftp ── lidar_huc         │
#   ortho_dl ─── ortho_index ── ortho_huc   (needs index AND dem)
#         (everything) ── check    (afterany; missing-output report)
#
# Satellite (sat_gee) was removed 2026-06: its outputs are not in the
# huc_stack.R band contract.
#
# Terrain curv/dmv, dropped at the same time, came back 2026-07 as extra BANDS
# of the slp stage's single output file (meanc_local, dmv_local) rather than as
# separate stages -- there is still exactly one terrain job in the graph. The
# multiscale (5/100/500 m) smoothing was removed with them. Terrain rasters
# written before that change have the wrong band set; the slp stage detects
# this by band name and rebuilds them, and check_stack_ready.sh / step_check
# report any that were missed as "terr-bands".
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

SELECTOR="$1"   # original "batch2"/"208,225" token, reused in fix-it messages
STEP="${2:-}"   # optional single stage to run instead of the full graph

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

# ── Single-step prerequisite checks (on-disk outputs) ───────────────────────
# Each verifies the upstream products a stage reads. Globs are relative to the
# project root (the cd at the top), matching the paths the step_*.sh scripts
# and their Rscripts use. On a miss they print the fix-it step and return 1.
# HUC products follow the cluster_<n>_huc_*.tif naming; the trailing "_huc_"
# keeps cluster 12 from matching cluster 120.

check_dem_sources() {  # DEM extraction reads source tiles from Data/DEMs/
    compgen -G "Data/DEMs/*" >/dev/null && return 0
    echo "ERROR: no DEM source tiles found in Data/DEMs/" >&2
    echo "       DEM extraction needs source tiles + NYS_All_DEM_Index.gpkg (manual prereq)." >&2
    return 1
}

check_huc_dems() {  # slp/hydro/chm/naip/ortho_huc all resample onto the HUC DEM
    local missing=() n
    for n in "${include[@]}"; do
        compgen -G "Data/TerrainProcessed/HUC_DEMs/cluster_${n}_huc_*.tif" >/dev/null \
            || missing+=("$n")
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0
    echo "ERROR: missing HUC DEMs for cluster(s): ${missing[*]}" >&2
    echo "       Run the DEM step first:  bash $0 $SELECTOR dem" >&2
    return 1
}

check_lidar_index() {  # lidar_ftp reads the merged collection index
    [[ -f "$LIDAR_INDEX" ]] && return 0
    echo "ERROR: lidar index not found: $LIDAR_INDEX" >&2
    echo "       Build it: Rscript R_Code_Analysis/download_lidar_indexes.R \\" >&2
    echo "              && Rscript R_Code_Analysis/build_lidar_index.R" >&2
    return 1
}

check_lidar_metrics() {  # lidar HUC merge reads per-tile metrics (not cluster-named)
    compgen -G "Data/Lidar/Metrics/*" >/dev/null && return 0
    echo "ERROR: no lidar metric tiles in Data/Lidar/Metrics/" >&2
    echo "       Run the lidar download first:  bash $0 $SELECTOR lidar_ftp" >&2
    return 1
}

check_ortho_tiles() {  # the footprint index is rebuilt over downloaded tiles
    compgen -G "Data/Ortho/Tiles/*" >/dev/null && return 0
    echo "ERROR: no ortho tiles in Data/Ortho/Tiles/" >&2
    echo "       Run the ortho download first:  bash $0 $SELECTOR ortho_dl" >&2
    return 1
}

check_ortho_index() {  # ortho_huc reads the rebuilt footprint index
    [[ -f "Data/Ortho/ortho_tiles.gpkg" ]] && return 0
    echo "ERROR: ortho footprint index not found: Data/Ortho/ortho_tiles.gpkg" >&2
    echo "       Build it:  bash $0 $SELECTOR ortho_index" >&2
    return 1
}

# ── Single-step mode: run exactly one stage, after checking its inputs ────────
if [[ -n "$STEP" ]]; then
    echo "Single-step mode: '$STEP'"
    case "$STEP" in
        dem)
            check_dem_sources || exit 1
            jid=$(submit "" "$SCRIPTDIR/step_dem.sh" "$INCLUDE_STR") ;;
        slp|terrain)
            check_huc_dems || exit 1
            jid=$(submit "" "$SCRIPTDIR/step_terrain.sh" "$INCLUDE_STR" slp) ;;
        hydro)
            check_huc_dems || exit 1
            jid=$(submit "" "$SCRIPTDIR/step_hydro.sh" "$INCLUDE_STR") ;;
        chm)
            check_huc_dems || exit 1
            jid=$(submit "" "$SCRIPTDIR/step_chm.sh" "$INCLUDE_STR") ;;
        naip)
            check_huc_dems || exit 1
            jid=$(submit "" "$SCRIPTDIR/step_naip.sh" "$INCLUDE_STR") ;;
        lidar_ftp)
            check_lidar_index || exit 1
            jid=$(submit "" "$SCRIPTDIR/step_lidar_ftp.sh" "$INCLUDE_STR") ;;
        lidar)
            check_lidar_metrics || exit 1
            jid=$(submit "" "$SCRIPTDIR/step_lidar.sh" "$INCLUDE_STR") ;;
        ortho_dl|ortho)
            jid=$(submit "" "$SCRIPTDIR/step_ortho.sh" "$INCLUDE_STR" "$ORTHO_YEAR" "$ORTHO_BANDS") ;;
        ortho_index)
            check_ortho_tiles || exit 1
            jid=$(submit "" "$SCRIPTDIR/step_ortho_index.sh") ;;
        ortho_huc)
            check_ortho_index || exit 1
            check_huc_dems || exit 1
            jid=$(submit "" "$SCRIPTDIR/step_ortho_huc.sh" "$INCLUDE_STR" "$ORTHO_YEAR") ;;
        check)
            jid=$(submit "" "$SCRIPTDIR/step_check.sh" "$INCLUDE_STR") ;;
        *)
            echo "ERROR: unknown step '$STEP'" >&2
            echo "Valid steps: dem slp hydro chm naip lidar_ftp lidar ortho_dl ortho_index ortho_huc check" >&2
            exit 1 ;;
    esac
    echo "  Job $jid"
    echo ""
    echo "Submitted step '$STEP' for clusters $INCLUDE_STR."
    echo "Monitor with: squeue -u \$USER"
    exit 0
fi

# ── DEM (root of the terrain-aligned steps) ─────────────────────────────────
echo "Submitting DEM extraction..."
jid_dem=$(submit "" "$SCRIPTDIR/step_dem.sh" "$INCLUDE_STR")
echo "  Job $jid_dem"

echo "Submitting terrain slope/geomorphons/meanc/dmv (after DEM)..."
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
