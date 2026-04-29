#!/bin/bash
# Master script – submits one SLURM job per processing step
# Usage: bash step_combined_master.sh
# Edit 'include' below to set which clusters to process.

cd /ibstorage/anthony/NYS_Wetlands_Data/

# ── Cluster numbers to process ───────────────────────────────────────────────
# include=(22)
### Batch 1
# include=(11 22 46 50 64 67 82 95 123 168 208 218 225 250)
### Batch 2
include=(1  2  3  4  5  6  7  8)
### Batch 3
#include=(9 10 12 13 14 15)
### Batch 4
#include=(16 17 18 19 20 21 23 24 25)
### Batch 5
#include=(26 27 28 29 30 31 32)
### Batch 6
#include=(33 34 35 36 37 38 39)
### Batch 7
#include=(40 41 42 43 44 45 47 48)
### Batch 8 
#include=(49 50 51 52 53 54)
### Batch 9
#include=(55 56 57 58 59 60 61 62 63)
### Batch 10
#include=(65 66 68 69 70 71)
### Batch 11
#include=(72 73 74 75 76 77 78 79)
### Batch 12
#include=(80 81 83 84 85 86 87)
### Batch 13
#include=(88 89 90 91 92 93 94 96 97)
### Batch 14
#include=(98  99 100 101 102 103 104 105)
### Batch 15
#include=(106 107 108 109)
### Batch 16
#include=(110 111 112 113 114 115 116)
### Batch 17
#include=(117 118 119 120 121 122 124 125 126 127 128)
### Batch 18
#include=(129 130 131 132 133 134)
### Batch 19
#include=(135 136 137 138 139 140)
### Batch 20
#include=(141 142 143 144 145 146 147)
### Batch 21
#include=(148 149 150 151 152 153 154 155 156 157 158)
### Batch 22
#include=(190 191 192 193 194 195)
### Batch 23
#include=(196 197 198 199 200 201)
### Batch 24
#include=(202 203 204 205 206 207 209)
### Batch 25
#include=(210 211 212 213 214 215 216 217 219 220 221)
### Batch 26
#include=(222 223 224 226 227 228)
### Batch 27
#include=(229 230 231 232 233 234)
### Batch 28
#include=(235 236 237 238 239 240)
### Batch 29
#include=(241 242 243 244 245 246 247 248 249)

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
