#!/bin/bash -l
#SBATCH --nodelist=cbsuxu04,cbsuxu05,cbsuxu06,cbsuxu07,cbsuxu08
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem-per-cpu=36G
#SBATCH --cpus-per-task=2
#SBATCH --job-name=dem_processing
#SBATCH --ntasks=5
#SBATCH --ntasks-per-node=1
#SBATCH --output=Shell_Scripts/SLURM/slurm-dems-%j.out

cd /ibstorage/anthony/NYS_Wetlands_Data/

export TMPDIR=/ibstorage/anthony/tmp

module load R/4.4.3


# Define the list of numbers
include=(225)
### Batch 1
# include=(11 22 46 50 64 67 82 95 123 168 208 218 225 250)
### Batch 2
# include=(1  2  3  4  5  6  7  8)
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
# Loop through each number in the list
for number in "${include[@]}"; do
    echo "Running Rscript with argument: $number"
    
    srun --nodes=1 --ntasks=1 --exclusive \
    Rscript R_Code_Analysis/DEM_Extract_singleVect_CMD.r \
        "Data/NYS_DEM_Indexes" \
        "Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg" \
        "$number" \
        "Data/DEMs/" \
        "Data/TerrainProcessed/HUC_DEMs/" >> "Shell_Scripts/logs/dem_processing_${number}_$(date +%Y%m%d).log" 2>&1 &

done

wait


