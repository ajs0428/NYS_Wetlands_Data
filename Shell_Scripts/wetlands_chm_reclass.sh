#!/bin/bash -l
#SBATCH --nodelist=cbsuxu01,cbsuxu02,cbsuxu03,cbsuxu04,cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem-per-cpu=16G
#SBATCH --cpus-per-task=3
#SBATCH --job-name=wetland_reclass
#SBATCH --ntasks=6
#SBATCH --ntasks-per-node=1
#SBATCH --output=Shell_Scripts/SLURM/slurm-wetland_reclass-%j.out


cd /ibstorage/anthony/NYS_Wetlands_Data/

export TMPDIR=/ibstorage/anthony/tmp

module load R/4.4.3

# Define the list of numbers
# include=(11 12 22 51 53 56 60 64 67 84 86 90 92 102 105 116 120 123 136 138 152 176 183 189 192 193 198 218 225 250)
### Batch 1
include=(11 22 46 50 64 67 82 95 123 168 208 218 225 250)
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

# Loop through each number in the list
for number in "${include[@]}"; do
    echo "Running Rscript with argument: $number"
    srun --nodes=1 --ntasks=1 --exclusive \
        Rscript R_Code_Analysis/Wetlands_CHM_reclass.R \
        "$number" \
        "Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg" \
        "Data/NWI/NY_NWI_6347.gpkg" \
        "ATTRIBUTE" >> "Shell_Scripts/logs/wetland_reclass_${number}_$(date +%Y%m%d).log" 2>&1 &
    
done

wait
echo "All Rscript executions completed."

