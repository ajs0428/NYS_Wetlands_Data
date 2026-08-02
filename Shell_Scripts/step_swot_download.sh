#!/bin/bash
#SBATCH --job-name=swot_dl
#SBATCH --partition=R256C128
#SBATCH --nodelist=cbsuxu09,cbsuxu10
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem-per-cpu=4G
#SBATCH --time=48:00:00
#SBATCH --output=/ibstorage/anthony/NYS_Wetlands_Data/Shell_Scripts/logs/swot_dl_%j.out
#SBATCH --error=/ibstorage/anthony/NYS_Wetlands_Data/Shell_Scripts/logs/swot_dl_%j.err

# Download SWOT_L2_HR_Raster_D into Data/SWOT/ via
# Python_Code_Analysis/download_swot_raster.py.
#
# This is network-bound, not compute-bound: --cpus-per-task only sets how many
# concurrent podaac-data-downloader processes we run, and one CPU is plenty per
# process. It is NOT part of step_combined_master.sh — SWOT is an independent
# data pull with no DEM dependency.
#
# Usage:
#   sbatch Shell_Scripts/step_swot_download.sh                      # NY, 100m, 2022-2025
#   sbatch Shell_Scripts/step_swot_download.sh --extent ghg --resolution both
#
# Any argument is passed straight through to the Python script; run
#   Python_Code_Analysis/download_swot_raster.py --help
# for the full list. Check the volume first with --report (no credentials, no
# SLURM needed):
#   Python_Code_Analysis/download_swot_raster.py --report --extent ny --resolution 100m
#
# Requires ~/.netrc with urs.earthdata.nasa.gov credentials; the script aborts
# with setup instructions if it is missing.
#
# Re-running is safe and cheap: already-downloaded files are skipped by
# checksum, so this doubles as the resume path after a timeout or failure.

set -euo pipefail

PROJECT=/ibstorage/anthony/NYS_Wetlands_Data
PYTHON="${PROJECT}/Python_Code_Analysis/envs/swot-dl/bin/python"

export TMPDIR="${PROJECT}/Data/tmp"
mkdir -p "$TMPDIR" "${PROJECT}/Shell_Scripts/logs" "${PROJECT}/Data/SWOT"

JOBS="${SLURM_CPUS_PER_TASK:-4}"

if [[ ! -x "$PYTHON" ]]; then
    echo "swot-dl env not found at ${PYTHON}. Create it with:" >&2
    echo "  python3 -m venv ${PROJECT}/Python_Code_Analysis/envs/swot-dl" >&2
    echo "  ${PROJECT}/Python_Code_Analysis/envs/swot-dl/bin/pip install podaac-data-subscriber" >&2
    exit 1
fi

# Default to whole-state 100 m if the caller passed nothing.
if [[ $# -eq 0 ]]; then
    set -- --extent ny --resolution 100m
fi

echo "host   : $(hostname)"
echo "jobs   : ${JOBS}"
echo "args   : $*"
echo "started: $(date)"

"$PYTHON" "${PROJECT}/Python_Code_Analysis/download_swot_raster.py" --jobs "$JOBS" "$@"
rc=$?

echo "finished: $(date) (rc=${rc})"
exit $rc
