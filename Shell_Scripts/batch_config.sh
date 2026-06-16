# Shared pipeline configuration + cluster batches
# Sourced by step_combined_master.sh and the step_*.sh scripts.

# ── Shared variables ─────────────────────────────────────────────────────────
PROJ_ROOT="/ibstorage/anthony/NYS_Wetlands_Data"
GPKG="Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg"
LOGDIR="Shell_Scripts/logs"

# Ortho imagery: preferred year. Where a cluster/HUC has no coverage for this
# year, both the download (Ortho_ftp.R) and the HUC compositing
# (Ortho_HUC_Processing.R) fall back to the nearest available year
# (newer wins ties), so HUCs stay single-year wherever possible.
ORTHO_YEAR=2024
ORTHO_BANDS=4bd

# Combined lidar tile index (all collections merged). Rebuild with
# R_Code_Analysis/build_lidar_index.R after download_lidar_indexes.R pulls
# any new collection index.
LIDAR_INDEX="Data/Lidar/NYS_Lidar_All_Indexes.gpkg"

# ── Batches for cluster processing ───────────────────────────────────────────
# NOTE: batch1-3 are the original pilot/priority sets; batch4-18 sweep all
# clusters 1-250 and therefore OVERLAP batch1-3 (e.g. 46 is in batch1 AND
# batch7). The per-step skip-if-exists checks make re-runs cheap, but don't
# run overlapping batches concurrently.
batch1=(11 22 46 50 64 67 82 95 123 168 208 218 225 250)
batch2=(12 51 53 56 60 84 86 90 92 102 105 116 120 136)
batch3=(138 152 153 176 183 187 189 192 193 198 204 240)
batch4=(1 2 3 4 5 6 7 8 9 10 13 14 15 16)
batch5=(17 18 19 20 21 23 24 25 26 27 28 29 30 31)
batch6=(32 33 34 35 36 37 38 39 40 41 42 43 44 45)
batch7=(46 47 48 49 52 54 55 57 58 59 61 62 63 65)
batch8=(66 68 69 70 71 72 73 74 75 76 77 78 79 80)
batch9=(81 82 83 85 87 88 89 91 93 94 95 96 97 98)
batch10=(99 100 101 103 104 106 107 108 109 110 111 112 113 114 245)
batch11=(115 117 118 119 121 122 124 125 126 127 128 129 130 131 246)
batch12=(132 133 134 135 137 139 140 141 142 143 144 145 146 147 247)
batch13=(148 149 150 151 154 155 156 157 158 159 160 161 162 163 248)
batch14=(164 165 166 167 168 169 170 171 172 173 174 175 177 178 249)
batch15=(179 180 181 182 184 185 186 188 190 191 194 195 196 197)
batch16=(199 200 201 202 203 205 206 207 209 210 211 212 213)
batch17=(214 215 216 217 219 220 221 222 223 224 226 227 228 229)
batch18=(230 231 232 233 234 235 236 237 238 239 241 242 243 244)
