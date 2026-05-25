#!/bin/bash
# Wrapper that runs the JP2-capable conda gdalwarp in an isolated subprocess.
# Ortho_ftp.R calls this via the ORTHO_GDALWARP env var. Activating the conda
# env here (instead of in the SLURM job) keeps conda's GDAL_DATA/PROJ_LIB out of
# the R process, so terra/sf keep using module-R's own GDAL/PROJ data.
source /workdir/ajs544/miniconda3/etc/profile.d/conda.sh
conda activate ortho
exec gdalwarp "$@"
