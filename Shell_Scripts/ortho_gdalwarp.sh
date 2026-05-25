#!/bin/bash
# Wrapper that runs the JP2-capable conda gdalwarp in an isolated subprocess.
# Ortho_ftp.R calls this via the ORTHO_GDALWARP env var. Keeping conda's setup
# in this subprocess (not the SLURM job) leaves R's terra/sf on module-R's GDAL.

ENV_PREFIX=/workdir/ajs544/miniconda3/envs/ortho

# Activate the env so GDAL_DATA / PROJ_LIB / PROJ_DATA are set (needed for CRS
# lookups during the warp).
source /workdir/ajs544/miniconda3/etc/profile.d/conda.sh
conda activate ortho

# `module load R` in the job sets LD_LIBRARY_PATH to system/R libs, which
# overrides conda's RPATH and makes libgdal load the system
# /lib64/libgcc_s.so.1 (missing GCC_12.0.0). Force the search path to the conda
# env lib ONLY so its newer libgcc wins; system libs (libc, etc.) still resolve
# from the default trusted dirs that are always searched.
export LD_LIBRARY_PATH="$ENV_PREFIX/lib"

# Call gdalwarp by full path so this does not depend on PATH/activation.
exec "$ENV_PREFIX/bin/gdalwarp" "$@"
