#!/bin/bash
# Master script – submits one SLURM job per processing step
# Usage: bash step_combined_master.sh
# Edit 'include' below to set which clusters to process.

cd /ibstorage/anthony/NYS_Wetlands_Data/

# ── Cluster numbers to process ───────────────────────────────────────────────
source Shell_Scripts/batch_config.sh
include=(225)
# include=("${batch1[@]}")

# Convert array to comma-separated string for passing to child scripts
INCLUDE_STR=$(IFS=,; echo "${include[*]}")

# ── Shared variables ─────────────────────────────────────────────────────────
GPKG="Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg"
LOGDIR="Shell_Scripts/logs"
SCRIPTDIR="Shell_Scripts"

# Ensure output dirs exist (no-op if already present)
mkdir -p "$LOGDIR" "$SCRIPTDIR/SLURM"

# ── Submit each processing step ──────────────────────────────────────────────
# DEM is the root: terrain (slp/curv/dmv), hydro, and sat_gee all read
# Data/TerrainProcessed/HUC_DEMs/, so they must wait for DEM to finish.
# CHM, lidar, and NAIP are independent and submit immediately.

echo "Submitting DEM processing..."
jid_dem=$(sbatch --parsable "$SCRIPTDIR/step_dem.sh" "$INCLUDE_STR")
echo "  Job $jid_dem"

echo "Submitting Sentinel GEE processing (after DEM)..."
jid_sat=$(sbatch --parsable --dependency=afterok:$jid_dem "$SCRIPTDIR/step_sat_gee.sh" "$INCLUDE_STR")
echo "  Job $jid_sat"

echo "Submitting terrain slope (after DEM)..."
jid_slp=$(sbatch --parsable --dependency=afterok:$jid_dem "$SCRIPTDIR/step_terrain.sh" "$INCLUDE_STR" slp)
echo "  Job $jid_slp"

echo "Submitting terrain curvature (after DEM)..."
jid_curv=$(sbatch --parsable --dependency=afterok:$jid_dem "$SCRIPTDIR/step_terrain.sh" "$INCLUDE_STR" curv)
echo "  Job $jid_curv"

echo "Submitting terrain dmv (after DEM)..."
jid_dmv=$(sbatch --parsable --dependency=afterok:$jid_dem "$SCRIPTDIR/step_terrain.sh" "$INCLUDE_STR" dmv)
echo "  Job $jid_dmv"

echo "Submitting Hydro extraction (after DEM)..."
jid_hydro=$(sbatch --parsable --dependency=afterok:$jid_dem "$SCRIPTDIR/step_hydro.sh" "$INCLUDE_STR")
echo "  Job $jid_hydro"

echo "Submitting CHM extraction..."
jid_chm=$(sbatch --parsable "$SCRIPTDIR/step_chm.sh" "$INCLUDE_STR")
echo "  Job $jid_chm"

### Make sure that lidar FTP files have been pulled
echo "Submitting lidar metrics..."
jid_lidar=$(sbatch --parsable "$SCRIPTDIR/step_lidar.sh" "$INCLUDE_STR")
echo "  Job $jid_lidar"

echo "Submitting NAIP processing..."
jid_naip=$(sbatch --parsable "$SCRIPTDIR/step_naip.sh" "$INCLUDE_STR")
echo "  Job $jid_naip"

echo ""
echo "All jobs submitted."
echo "Monitor with: squeue -u \$USER"
