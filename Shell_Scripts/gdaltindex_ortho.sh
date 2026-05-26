#!/bin/bash -l
# =============================================================================
# Build a tile-footprint index over the downloaded ortho GeoTIFFs so the
# HUC processor can spatially filter which tiles overlap each HUC12 without
# opening every raster. Mirrors gdaltindex_naip.sh.
#
#   Usage:  bash Shell_Scripts/gdaltindex_ortho.sh
#
# The ortho tiles are already plain GeoTIFFs (EPSG:6347, 1 m), so the system
# GDAL is fine here -- no JP2 driver needed (that was only for the download
# step's gdalwarp). Output: Data/Ortho/ortho_tiles.gpkg with a `location`
# column holding paths like "Tiles/c_..._<year>.tif" relative to Data/Ortho/.
#
# Re-run this after every ortho download batch: it REBUILDS the index from
# scratch (deletes the old gpkg first) so it always reflects the current set
# of tiles on disk -- footprints are cheap to regenerate.
# =============================================================================
cd /ibstorage/anthony/NYS_Wetlands_Data/Data/Ortho/
export PATH=/programs/gdal-3.5.2/bin:$PATH
export LD_LIBRARY_PATH=/programs/gdal-3.5.2/lib

gpkg_file="ortho_tiles.gpkg"
tiles_dir="Tiles"

if [ -f "$gpkg_file" ]; then
    echo "Removing stale index: $gpkg_file"
    rm -f "$gpkg_file"
fi

echo "Creating index '$gpkg_file' from ${tiles_dir}/*.tif ..."
find "$tiles_dir" -name "*.tif" -print0 | xargs -0 gdaltindex -t_srs EPSG:6347 "$gpkg_file"
echo "Done. Indexed $(find "$tiles_dir" -name '*.tif' | wc -l) tiles into $gpkg_file"
