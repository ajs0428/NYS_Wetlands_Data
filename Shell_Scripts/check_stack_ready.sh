#!/bin/bash -l
set -uo pipefail

# check_stack_ready.sh -- quick stack-readiness report for the DL pipeline.
#
# For every HUC12 in the selected clusters, checks that each of the seven
# source datasets consumed by huc_stack.R (dem, terr-slp, hydro, chm, naip,
# ortho, lidar) has at least one file on disk, i.e. whether huc_layers() /
# build_huc_stack_* could assemble the prediction stack for that HUC. Pure
# filesystem check -- no SLURM, no R (except a one-time cluster->huc12 dump
# from the GPKG, cached and refreshed only when the GPKG changes).
#
# The per-dataset file-selection rules mirror huc_source_paths()/match_one()
# in R_Code_Analysis/huc_stack.R (and keep_file() in the DL project's
# rsync_huc_sources.sh):
#   dem  -> exclude whitebox ("wbt") intermediates
#   terr -> the local slope file, excluding 10m / 1000m scales
#   rest -> any .tif matching the huc id and the exact cluster
#
# The terrain file is additionally opened (gdalinfo header read) and its band
# descriptions compared against TERR_BANDS below. A terrain raster written
# before meanc/dmv were folded in (2026-07) still exists on disk and so would
# pass a presence-only check while silently narrowing the DL stack; those HUCs
# are reported as missing "terr-bands". This costs ~0.1 s per HUC -- pass
# --no-bands for the old presence-only behaviour (noticeably faster on "all").
#
# Usage:
#   bash Shell_Scripts/check_stack_ready.sh <SELECTION...> [-o OUTFILE] [--no-bands]
#
#   SELECTION  one or more of:
#     batchN         a batch name from Shell_Scripts/batch_config.sh
#     N[,N,...]      cluster number(s), comma or space separated
#     all            every cluster/huc pair in the GPKG
#
# Examples:
#   bash Shell_Scripts/check_stack_ready.sh batch1
#   bash Shell_Scripts/check_stack_ready.sh batch1 batch2
#   bash Shell_Scripts/check_stack_ready.sh 208,225 -o /tmp/ready.txt
#   bash Shell_Scripts/check_stack_ready.sh all --no-bands
#
# Output (two files):
#   OUTFILE                 tab-separated report:
#                             valid  batch_num  cluster:huc  [missing:...]
#                             yes  1     208:041402011002
#                             no   1,9   64:020200040404   missing:chm,lidar
#                             no   2     12:041300010203   missing:terr-bands
#                           batch_num is the batchN name(s) from batch_config.sh
#                           containing that cluster ("-" if none, comma-joined
#                           when a cluster sits in more than one batch).
#   OUTFILE minus .txt + _valid_pairs.txt
#                           only the ready cluster:huc pairs, one per line --
#                           feed it straight to the DL project's
#                           rsync_huc_sources.sh --pairs <file>

cd /ibstorage/anthony/NYS_Wetlands_Data/
source Shell_Scripts/batch_config.sh   # GPKG + batchN arrays

# === SOURCE LAYOUT (mirrors huc_source_dirs() in huc_stack.R) ===
KEYS="dem terr hydro chm naip ortho lidar"

subdir_for() {
    case "$1" in
        dem)   echo "Data/TerrainProcessed/HUC_DEMs" ;;
        terr)  echo "Data/TerrainProcessed/HUC_TerrainMetrics" ;;
        hydro) echo "Data/TerrainProcessed/HUC_Hydro" ;;
        chm)   echo "Data/CHMs/HUC_CHMs" ;;
        naip)  echo "Data/NAIP/HUC_NAIP_Processed" ;;
        ortho) echo "Data/Ortho/HUC_Ortho" ;;
        lidar) echo "Data/Lidar/HUC_Lidar_Metrics" ;;
    esac
}

# Band contract of the combined terrain raster, in order. Mirrors
# TERRAIN_BANDS in R_Code_Analysis/terrain_metrics_filter_singleVect_CMD.R
# (the producer) and terr_expected_bands() in R_Code_Analysis/huc_stack.R.
TERR_BANDS="slope_local TPI_local Geomorph_local meanc_local dmv_local"

# The system gdalinfo (/usr/local/bin) is broken against the current libgdal;
# the packaged 3.4 CLI is the working one (see also step_hydro.sh). Override
# with GDALINFO=... if that changes.
GDALINFO="${GDALINFO:-/usr/bin/gdal3.4-gdalinfo}"

# === ARGS ===
OUTFILE=""
CHECK_BANDS=1
SELECTORS=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o|--out)
            shift
            [ "$#" -ge 1 ] || { echo "ERROR: -o needs a file argument" >&2; exit 1; }
            OUTFILE="$1" ;;
        --no-bands)
            CHECK_BANDS=0 ;;
        -h|--help)
            grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'
            exit 0 ;;
        *) SELECTORS+=("$1") ;;
    esac
    shift
done
if [ "${#SELECTORS[@]}" -eq 0 ]; then
    echo "Usage: $(basename "$0") <batchN | clusters | all> [-o OUTFILE]  (-h for details)" >&2
    exit 1
fi

# === CLUSTER -> HUC12 lookup (cached dump of the GPKG attribute table) ===
PAIRS_CACHE="Data/NY_HUCS/cluster_huc12_pairs.txt"
if [ ! -s "$PAIRS_CACHE" ] || [ "$GPKG" -nt "$PAIRS_CACHE" ]; then
    echo "Refreshing cluster->huc12 cache from $GPKG ..."
    command -v module >/dev/null && module load R/4.4.3
    Rscript -e '
        suppressMessages(library(sf))
        a <- commandArgs(TRUE)
        x <- unique(st_drop_geometry(st_read(a[1], quiet = TRUE))[, c("cluster", "huc12")])
        x$huc12 <- formatC(x$huc12, width = 12, flag = "0")   # keep leading zeros
        x <- x[order(as.numeric(x$cluster), x$huc12), ]
        write.table(x, a[2], sep = " ", row.names = FALSE, col.names = FALSE, quote = FALSE)
    ' "$GPKG" "$PAIRS_CACHE" || { echo "ERROR: could not dump $GPKG" >&2; exit 1; }
    echo "Cached $(wc -l < "$PAIRS_CACHE") cluster/huc pairs in $PAIRS_CACHE"
fi

# === RESOLVE SELECTION -> unique cluster list ===
CLUSTERS=()
ALL=0
for sel in "${SELECTORS[@]}"; do
    if [ "$sel" = "all" ]; then
        ALL=1
    elif [[ "$sel" =~ ^batch[0-9]+$ ]]; then
        if ! declare -p "$sel" >/dev/null 2>&1; then
            echo "ERROR: $sel is not defined in batch_config.sh" >&2; exit 1
        fi
        declare -n _batch="$sel"
        CLUSTERS+=("${_batch[@]}")
        unset -n _batch
    else
        for c in ${sel//,/ }; do
            [[ "$c" =~ ^[0-9]+$ ]] || { echo "ERROR: bad cluster '$c' in '$sel'" >&2; exit 1; }
            CLUSTERS+=("$c")
        done
    fi
done
if [ "$ALL" -eq 1 ]; then
    mapfile -t CLUSTERS < <(awk '{print $1}' "$PAIRS_CACHE" | sort -un)
else
    mapfile -t CLUSTERS < <(printf '%s\n' "${CLUSTERS[@]}" | sort -un)
fi

# === CLUSTER -> BATCH NUMBER(S) ===
# Every batchN array in batch_config.sh, inverted. A cluster can appear in more
# than one batch (e.g. 46 is in batch1 and batch7), so values are comma-joined;
# clusters in no batch get "-".
declare -A BATCH_OF=()
for bname in $(compgen -A variable | grep -E '^batch[0-9]+$' | sort -t h -k2 -n); do
    declare -n _b="$bname"
    for c in "${_b[@]}"; do
        if [ -n "${BATCH_OF[$c]:-}" ]; then
            BATCH_OF[$c]="${BATCH_OF[$c]},${bname#batch}"
        else
            BATCH_OF[$c]="${bname#batch}"
        fi
    done
    unset -n _b
done

# === OUTPUT FILES ===
TAG="$(printf '%s-' "${SELECTORS[@]}")"; TAG="${TAG%-}"; TAG="${TAG//,/_}"
[ -n "$OUTFILE" ] || OUTFILE="Shell_Scripts/logs/stack_ready_${TAG}_$(date +%Y%m%d_%H%M%S).txt"
PAIRSFILE="${OUTFILE%.txt}_valid_pairs.txt"
mkdir -p "$(dirname "$OUTFILE")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# List each dataset dir ONCE (basenames only), then filter per cluster/huc.
for key in $KEYS; do
    ls "$(subdir_for "$key")" 2>/dev/null | grep '\.tif$' > "$TMP/$key.all" || true
done

# First file for this huc in a per-cluster listing, after the dataset-specific
# filters (mirrors keep_file / match_one). Echoes the basename, or nothing.
find_source() {
    local key="$1" huc="$2" listing="$3"
    case "$key" in
        dem)  grep -F "$huc" "$listing" | grep -v 'wbt'        | head -1 ;;
        terr) grep -F "$huc" "$listing" | grep 'slp' | grep 'local' \
                                        | grep -vE '10m|1000m' | head -1 ;;
        *)    grep -F "$huc" "$listing" | head -1 ;;
    esac
}

# Do the terrain raster's band descriptions match TERR_BANDS exactly, in order?
# Header read only -- gdalinfo does not touch the pixel data.
terr_bands_ok() {
    local got
    got="$("$GDALINFO" "$1" 2>/dev/null \
           | sed -nE 's/^ *Description = (.*)$/\1/p' | tr '\n' ' ')"
    # unquoted $got / $TERR_BANDS collapses whitespace on both sides
    [ "$(echo $got)" = "$(echo $TERR_BANDS)" ]
}

if [ "$CHECK_BANDS" -eq 1 ] && ! command -v "$GDALINFO" >/dev/null 2>&1; then
    echo "WARNING: $GDALINFO not found -- skipping the terrain band check." >&2
    echo "         (set GDALINFO=... or pass --no-bands to silence this)" >&2
    CHECK_BANDS=0
fi

{
    echo "# stack-readiness report  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# selection: ${SELECTORS[*]}  (${#CLUSTERS[@]} clusters)"
    echo "# datasets checked: $KEYS  (band contract of R_Code_Analysis/huc_stack.R)"
    [ "$CHECK_BANDS" -eq 1 ] \
        && echo "# terrain bands required: $TERR_BANDS" \
        || echo "# terrain band check: DISABLED (--no-bands)"
    echo "# columns: valid <TAB> batch_num <TAB> cluster:huc <TAB> missing datasets (if any)"
} > "$OUTFILE"
: > "$PAIRSFILE"

N_OK=0; N_BAD=0; N_TOTAL=0
for cl in "${CLUSTERS[@]}"; do
    # HUCs for this cluster from the cache.
    mapfile -t hucs < <(awk -v c="$cl" '$1 == c {print $2}' "$PAIRS_CACHE")
    if [ "${#hucs[@]}" -eq 0 ]; then
        echo "WARNING: cluster $cl has no HUCs in $PAIRS_CACHE -- skipped" >&2
        continue
    fi
    batch_num="${BATCH_OF[$cl]:--}"
    # Pre-filter every dataset listing to this exact cluster (208, not 20/2080).
    for key in $KEYS; do
        grep -E "cluster_${cl}([^0-9]|$)" "$TMP/$key.all" > "$TMP/$key.cl" || true
    done
    for huc in "${hucs[@]}"; do
        N_TOTAL=$((N_TOTAL + 1))
        missing=()
        for key in $KEYS; do
            hit="$(find_source "$key" "$huc" "$TMP/$key.cl")"
            if [ -z "$hit" ]; then
                missing+=("$key")
            elif [ "$key" = "terr" ] && [ "$CHECK_BANDS" -eq 1 ] \
                 && ! terr_bands_ok "$(subdir_for terr)/$hit"; then
                # present but stale (e.g. no meanc/dmv) -- unusable for stacking
                missing+=("terr-bands")
            fi
        done
        if [ "${#missing[@]}" -eq 0 ]; then
            printf 'yes\t%s\t%s:%s\n' "$batch_num" "$cl" "$huc" >> "$OUTFILE"
            printf '%s:%s\n'      "$cl" "$huc" >> "$PAIRSFILE"
            N_OK=$((N_OK + 1))
        else
            printf 'no\t%s\t%s:%s\tmissing:%s\n' "$batch_num" "$cl" "$huc" \
                   "$(IFS=,; echo "${missing[*]}")" >> "$OUTFILE"
            N_BAD=$((N_BAD + 1))
        fi
    done
done

echo "=============================================================="
echo "Stack-ready HUCs: $N_OK / $N_TOTAL   (not ready: $N_BAD)"
echo "Report:      $OUTFILE"
echo "Valid pairs: $PAIRSFILE"
echo "  transfer:  ./rsync_huc_sources.sh --pairs $PAIRSFILE   (in NYS_Wetlands_DL/Shell_Scripts)"
echo "=============================================================="
[ "$N_BAD" -eq 0 ]
