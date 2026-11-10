#!/bin/bash -l
#SBATCH --partition=R256C128
#SBATCH --nodes=1   # NOT --nodelist=09,10: that forces EVERY array element onto both nodes
#SBATCH --mail-user=ajs544@cornell.edu
#SBATCH --mail-type=END,FAIL
#SBATCH --mem=40G
#SBATCH --cpus-per-task=1
#SBATCH --array=1-16
#SBATCH --job-name=ortho_qa
#SBATCH --output=Shell_Scripts/SLURM/slurm-ortho-qa-%A_%a.out

# =============================================================================
# Within-HUC12-polygon QA of the leaf-off ortho rasters (Ortho_HUC_QA.R).
#   Usage: sbatch Shell_Scripts/ortho_huc_qa.sh [qaDir]
# One array element per file slice (round-robin over SLURM_ARRAY_TASK_COUNT).
# A job array, not srun steps inside one job: with the SLURM mem vars unset,
# steps got no fixed memory share and only ~5 of 16 ever started.
# Peak RSS is 24-30+ GB per task (sacct, jobs 792811/792846), hence 40G; that is
# 6 per node (12 at once) and the rest start as slots free.
# Resumable: every element skips HUCs already in ANY <qaDir>/parts/*.csv.
# Combine:  Rscript -e 'write.csv(do.call(rbind, lapply(Sys.glob("Data/Ortho/QA/parts/ortho_qa_*.csv"), read.csv)), "Data/Ortho/QA/ortho_qa.csv", row.names=FALSE)'
# =============================================================================

cd /ibstorage/anthony/NYS_Wetlands_Data/
export TMPDIR=/ibstorage/anthony/NYS_Wetlands_Data/Data/tmp/
module load R/4.4.3
source Shell_Scripts/batch_config.sh   # GPKG

QA_DIR=${1:-Data/Ortho/QA}
export TASK_MEM_MB=$(( 40 * 1024 ))
unset SLURM_MEM_PER_CPU SLURM_MEM_PER_NODE SLURM_MEM_PER_GPU

Rscript R_Code_Analysis/Ortho_HUC_QA.R "$GPKG" Data/Ortho/HUC_Ortho "$QA_DIR" \
    "$SLURM_ARRAY_TASK_ID" "$SLURM_ARRAY_TASK_COUNT"
