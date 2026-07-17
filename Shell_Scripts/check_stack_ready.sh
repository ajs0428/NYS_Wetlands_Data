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
# Usage:
#   bash Shell_Scripts/check_stack_ready.sh <SELECTION...> [-o OUTFILE]
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
#   bash Shell_Scripts/check_stack_ready.sh all
#
# Output (two files):
#   OUTFILE                 tab-separated report:  valid  cluster:huc  [missing:...]
#                             yes  208:041402011002
#                             no   64:020200040404   missing:chm,lidar
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

# === ARGS ===
OUTFILE=""
SELECTORS=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o|--out)
            shift
            [ "$#" -ge 1 ] || { echo "ERROR: -o needs a file argument" >&2; exit 1; }
            OUTFILE="$1" ;;
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

# At least one file for this huc in a per-cluster listing, after the
# dataset-specific filters? (mirrors keep_file / match_one)
has_source() {
    local key="$1" huc="$2" listing="$3" hit=""
    case "$key" in
        dem)  hit="$(grep -F "$huc" "$listing" | grep -v 'wbt'        | head -1)" ;;
        terr) hit="$(grep -F "$huc" "$listing" | grep 'slp' | grep 'local' \
                                               | grep -vE '10m|1000m' | head -1)" ;;
        *)    hit="$(grep -F "$huc" "$listing" | head -1)" ;;
    esac
    [ -n "$hit" ]
}

{
    echo "# stack-readiness report  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# selection: ${SELECTORS[*]}  (${#CLUSTERS[@]} clusters)"
    echo "# datasets checked: $KEYS  (band contract of R_Code_Analysis/huc_stack.R)"
    echo "# columns: valid <TAB> cluster:huc <TAB> missing datasets (if any)"
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
    # Pre-filter every dataset listing to this exact cluster (208, not 20/2080).
    for key in $KEYS; do
        grep -E "cluster_${cl}([^0-9]|$)" "$TMP/$key.all" > "$TMP/$key.cl" || true
    done
    for huc in "${hucs[@]}"; do
        N_TOTAL=$((N_TOTAL + 1))
        missing=()
        for key in $KEYS; do
            has_source "$key" "$huc" "$TMP/$key.cl" || missing+=("$key")
        done
        if [ "${#missing[@]}" -eq 0 ]; then
            printf 'yes\t%s:%s\n' "$cl" "$huc" >> "$OUTFILE"
            printf '%s:%s\n'      "$cl" "$huc" >> "$PAIRSFILE"
            N_OK=$((N_OK + 1))
        else
            printf 'no\t%s:%s\tmissing:%s\n' "$cl" "$huc" \
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
