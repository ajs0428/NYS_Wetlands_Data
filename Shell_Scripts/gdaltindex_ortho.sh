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

# The 2026-07 PROJ 9.6 update removed libproj.so.22, killing /programs/gdal-3.5.2
# (and /usr/local's GDAL). The RPM GDAL 3.4.3 binaries (/usr/bin/gdal3.4-*) are
# the only working CLIs on the cbsuxu nodes now.
GDALTINDEX=/usr/bin/gdal3.4-gdaltindex

gpkg_file="ortho_tiles.gpkg"
tiles_dir="Tiles"

if [ -f "$gpkg_file" ]; then
    echo "Removing stale index: $gpkg_file"
    rm -f "$gpkg_file"
fi

echo "Creating index '$gpkg_file' from ${tiles_dir}/*.tif ..."
find "$tiles_dir" -name "*.tif" -print0 | xargs -0 "$GDALTINDEX" -t_srs EPSG:6347 "$gpkg_file"
xargs_status=$?

# xargs splits 51k+ paths across many gdaltindex invocations; every one must
# succeed or the index silently misses tiles. Verify status AND (when sqlite3
# is on PATH — it's a conda binary) feature count against the on-disk tile
# count, so a partial/failed build exits nonzero (step_ortho_index.sh
# propagates this and afterok blocks the HUC stage).
if [ "$xargs_status" -ne 0 ] || [ ! -f "$gpkg_file" ]; then
    echo "ERROR: gdaltindex failed (xargs status $xargs_status); $gpkg_file not built" >&2
    exit 1
fi
n_tiles=$(find "$tiles_dir" -name '*.tif' | wc -l)
if command -v sqlite3 >/dev/null; then
    layer=$(sqlite3 "$gpkg_file" "SELECT table_name FROM gpkg_contents LIMIT 1")
    n_indexed=$(sqlite3 "$gpkg_file" "SELECT COUNT(*) FROM \"$layer\"")
    if [ "$n_indexed" -ne "$n_tiles" ]; then
        echo "ERROR: incomplete index: $n_indexed of $n_tiles tiles in $gpkg_file" >&2
        exit 1
    fi
    echo "Done. Indexed $n_indexed tiles into $gpkg_file"
else
    echo "Done (feature-count check skipped: no sqlite3). $n_tiles tiles on disk -> $gpkg_file"
fi
