#!/bin/bash -l
#SBATCH --nodelist=cbsuxu06,cbsuxu07,cbsuxu08,cbsuxu09,cbsuxu10
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=ALL
#SBATCH --mem=8G
#SBATCH --job-name=pipeline_check
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --output=Shell_Scripts/SLURM/slurm-check-%j.out

# =============================================================================
# PIPELINE OUTPUT CHECK -- final job in the step_combined_master.sh chain
# (submitted afterany: every leaf job, so it runs even when a step failed).
#
#   Usage:  sbatch step_check.sh "<comma-sep clusters>"
#
# Runs Pipeline_Check_CMD.R, which verifies that every HUC12 in the given
# clusters has a file in each of the seven source dirs of huc_stack.R's band
# contract. The job FAILS (non-zero exit -> mail) when anything is missing;
# the per-HUC detail lands in Shell_Scripts/logs/pipeline_check_*.log and a
# CSV of missing HUCs in Shell_Scripts/logs/pipeline_check_missing_*.csv.
# =============================================================================

cd /ibstorage/anthony/NYS_Wetlands_Data/
module load R/4.4.3

source Shell_Scripts/batch_config.sh   # GPKG

DATE=$(date +%Y%m%d_%H%M%S)
LOG="Shell_Scripts/logs/pipeline_check_${DATE}.log"

Rscript R_Code_Analysis/Pipeline_Check_CMD.R "$GPKG" "$1" 2>&1 | tee "$LOG"
exit "${PIPESTATUS[0]}"
