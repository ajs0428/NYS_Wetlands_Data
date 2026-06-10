#!/usr/bin/env Rscript
# =============================================================================
# Rebuild the combined lidar tile index from the per-collection indexes.
#
#   Usage:  Rscript R_Code_Analysis/build_lidar_index.R
#
# Merges every gpkg in Data/Lidar/Indexes/ (downloaded by
# download_lidar_indexes.R) into Data/Lidar/NYS_Lidar_All_Indexes.gpkg.
# This file is read by LIDAR_ftp.R (tile selection for download) and
# Lidar_HUC_Processing.R (tile-to-HUC matching), so BOTH stages see the same
# tile set. Re-run after downloading any new collection index.
#
# This is the code that previously lived commented-out inside
# Lidar_HUC_Processing.R; the output format is unchanged (FILENAME,
# COLLECTION*/COLLECT* columns, DIRECT_DL, geometry in EPSG:6347).
# =============================================================================

library(sf)
library(dplyr)

index_dir <- "Data/Lidar/Indexes"
out_file  <- "Data/Lidar/NYS_Lidar_All_Indexes.gpkg"

lidar_index_list <- list.files(index_dir, pattern = "\\.gpkg$", full.names = TRUE)
if (length(lidar_index_list) == 0) {
    stop("No collection indexes found in ", index_dir,
         " -- run download_lidar_indexes.R first.")
}
message("Merging ", length(lidar_index_list), " collection indexes from ", index_dir)

lidar_index_all_sf <- lapply(lidar_index_list, \(x) {
        message("  ", basename(x))
        st_read(x, quiet = TRUE) |>
            st_transform("EPSG:6347") |>
            dplyr::select(FILENAME, starts_with("COLLECT"), DIRECT_DL) |>
            st_make_valid()
    }) |>
    bind_rows()

message("Total tiles in combined index: ", nrow(lidar_index_all_sf))
write_sf(lidar_index_all_sf, out_file, append = FALSE)
message("Wrote: ", out_file)
