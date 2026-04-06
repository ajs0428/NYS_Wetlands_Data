#!/bin/bash
# Master script – submits one SLURM job per processing step
# Usage: bash step_combined_master.sh
# Edit 'include' below to set which clusters to process.

cd /ibstorage/anthony/NYS_Wetlands_Data/

# ── Cluster numbers to process ───────────────────────────────────────────────
include=(168)

# Convert array to comma-separated string for passing to child scripts
INCLUDE_STR=$(IFS=,; echo "${include[*]}")

# ── Shared variables ─────────────────────────────────────────────────────────
GPKG="Data/NY_HUCS/NY_Cluster_Zones_250_NAomit_6347.gpkg"
LOGDIR="Shell_Scripts/logs"
SCRIPTDIR="Shell_Scripts"

# ── Submit each processing step ──────────────────────────────────────────────

echo "Submitting terrain slope..."
jid_slp=$(sbatch --parsable --mem-per-cpu=64G --cpus-per-task=2 "$SCRIPTDIR/step_terrain.sh" "$INCLUDE_STR" slp)
echo "  Job $jid_slp"

echo "Submitting terrain curvature..."
jid_curv=$(sbatch --parsable --mem-per-cpu=96G --cpus-per-task=2 "$SCRIPTDIR/step_terrain.sh" "$INCLUDE_STR" curv)
echo "  Job $jid_curv"

echo "Submitting terrain dmv..."
jid_dmv=$(sbatch --parsable --mem-per-cpu=48G --cpus-per-task=3 "$SCRIPTDIR/step_terrain.sh" "$INCLUDE_STR" dmv)
echo "  Job $jid_dmv"

echo "Submitting CHM extraction..."
jid_chm=$(sbatch --parsable --mem-per-cpu=36G --cpus-per-task=4 "$SCRIPTDIR/step_chm.sh" "$INCLUDE_STR")
echo "  Job $jid_chm"

echo "Submitting lidar metrics..."
jid_lidar=$(sbatch --parsable --mem-per-cpu=16G --cpus-per-task=8 "$SCRIPTDIR/step_lidar.sh" "$INCLUDE_STR")
echo "  Job $jid_lidar"

echo "Submitting NAIP processing..."
jid_naip=$(sbatch --parsable --mem-per-cpu=64G --cpus-per-task=2 "$SCRIPTDIR/step_naip.sh" "$INCLUDE_STR")
echo "  Job $jid_naip"

echo "Submitting Sentinel GEE processing..."
jid_sat=$(sbatch --parsable --mem-per-cpu=32G --cpus-per-task=5 "$SCRIPTDIR/step_sat_gee.sh" "$INCLUDE_STR")
echo "  Job $jid_sat"

echo ""
echo "All jobs submitted."
echo "Monitor with: squeue -u \$USER"
