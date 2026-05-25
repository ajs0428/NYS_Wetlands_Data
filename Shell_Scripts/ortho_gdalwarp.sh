#!/bin/bash
# Wrapper that runs the JP2-capable conda gdalwarp in an isolated subprocess.
# Ortho_ftp.R calls this via the ORTHO_GDALWARP env var. Keeping conda's GDAL out
# of this subprocess (not the SLURM job) leaves R's terra/sf on module-R's GDAL.
#
# IMPORTANT: the conda 'ortho' env MUST live on shared storage (/ibstorage), NOT
# node-local /workdir. SLURM runs on cbsuxu06-10 and each node's /workdir is a
# separate physical disk, so an env created in /workdir on one node is invisible
# to the job -- every tile then fails the reproject. See ENV_PREFIX below.
ENV_PREFIX=/ibstorage/anthony/conda_envs/ortho

# A conda env is self-contained, so we set its data dirs by hand and call the
# binary directly. This avoids sourcing conda.sh / `conda activate`, so the
# wrapper does NOT depend on the miniconda *install* location (also node-local)
# -- only on ENV_PREFIX being on shared storage.
export GDAL_DATA="$ENV_PREFIX/share/gdal"
export PROJ_DATA="$ENV_PREFIX/share/proj"
export PROJ_LIB="$ENV_PREFIX/share/proj"

# `module load R` in the job sets LD_LIBRARY_PATH to system/R libs, which would
# override the env's RPATH and make libgdal load the system /lib64/libgcc_s.so.1
# (missing GCC_12.0.0). Point the search path at the env lib ONLY so its newer
# libgcc wins; system libs (libc, etc.) still resolve from the default trusted
# dirs that are always searched.
export LD_LIBRARY_PATH="$ENV_PREFIX/lib"

# Call gdalwarp by full path so this does not depend on PATH/activation.
exec "$ENV_PREFIX/bin/gdalwarp" "$@"
