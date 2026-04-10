#!/bin/bash
# Master script – submits one SLURM job per processing step
# Usage: bash step_combined_master.sh
# Edit 'include' below to set which clusters to process.

cd /ibstorage/anthony/NYS_Wetlands_Data/

# ── Cluster numbers to process ───────────────────────────────────────────────
include=(22)
### Batch 1
# include=(11 22 46 50 64 67 82 95 123 168 208 218 225 250)
### Batch 2
#include=(1  2  3  4  5  6  7  8  9 10 12 13 14 15 16 17 18 19 20 21 23 24 25 26 27 28 29 30 31 32)
### Batch 3
# include=(33 34 35 36 37 38 39 40 41 42 43 44 45 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63)
### Batch 4
# include=(65 66 68 69 70 71 72 73 74 75 76 77 78 79 80 81 83 84 85 86 87 88 89 90 91 92 93 94 96 97)
### Batch 5
# include=(98  99 100 101 102 103 104 105 106 107 108 109 110 111 112 113 114 115 116 117 118 119 120 121 122 124 125 126 127 128)
### Batch 6
# include=(129 130 131 132 133 134 135 136 137 138 139 140 141 142 143 144 145 146 147 148 149 150 151 152 153 154 155 156 157 158)
### Batch 7
# include=(190 191 192 193 194 195 196 197 198 199 200 201 202 203 204 205 206 207 209 210 211 212 213 214 215 216 217 219 220 221)
### Batch 8
# include=(222 223 224 226 227 228 229 230 231 232 233 234 235 236 237 238 239 240 241 242 243 244 245 246 247 248 249)

# Convert array to comma-separated string for passing to child scripts
INCLUDE_STR=$(IFS=,; echo "${include[*]}")

# ── Shared variables ─────────────────────────────────────────────────────────
GPKG="Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg"
LOGDIR="Shell_Scripts/logs"
SCRIPTDIR="Shell_Scripts"

# ── Submit each processing step ──────────────────────────────────────────────

echo "Submitting terrain slope..."
jid_slp=$(sbatch --parsable "$SCRIPTDIR/step_terrain.sh" "$INCLUDE_STR" slp)
echo "  Job $jid_slp"

echo "Submitting terrain curvature..."
jid_curv=$(sbatch --parsable "$SCRIPTDIR/step_terrain.sh" "$INCLUDE_STR" curv)
echo "  Job $jid_curv"

echo "Submitting terrain dmv..."
jid_dmv=$(sbatch --parsable "$SCRIPTDIR/step_terrain.sh" "$INCLUDE_STR" dmv)
echo "  Job $jid_dmv"

echo "Submitting Hydro extraction..."
jid_hydro=$(sbatch --parsable "$SCRIPTDIR/step_hydro.sh" "$INCLUDE_STR")
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

echo "Submitting Sentinel GEE processing..."
jid_sat=$(sbatch --parsable "$SCRIPTDIR/step_sat_gee.sh" "$INCLUDE_STR")
echo "  Job $jid_sat"

echo ""
echo "All jobs submitted."
echo "Monitor with: squeue -u \$USER"
