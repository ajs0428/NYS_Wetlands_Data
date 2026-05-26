#!/usr/bin/env Rscript

###################
# For each HUC12 in a cluster, mosaic the downloaded ortho tiles that overlap
# the HUC12, crop/mask to the HUC12 boundary, and resample onto that HUC12's
# DEM raster so the ortho aligns pixel-for-pixel with the terrain/LiDAR stack.
#
# Tiles come from Ortho_ftp.R (EPSG:6347, 1 m, 4-band leaf-off NYSDOP imagery).
# Which tiles overlap a HUC12 is resolved from the footprint index built by
# Shell_Scripts/gdaltindex_ortho.sh. Mirrors NAIP_Processing_CMD.R.
###################

args = c(
    "Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg",
    208,
    2023,
    "Data/Ortho/ortho_tiles.gpkg",
    "Data/TerrainProcessed/HUC_DEMs",
    "Data/Ortho/HUC_Ortho/",
    ""
)
args = commandArgs(trailingOnly = TRUE) # arguments are passed from terminal to here

clusterPath   <- args[1]
clusterSubset <- args[2]
year          <- args[3]
orthoIndex    <- args[4]
demDir        <- args[5]
outputPath    <- args[6]
targetHuc     <- if (length(args) >= 7) args[7] else ""  # optional single HUC12

message("these are the arguments: \n",
    "- Path to cluster gpkg:", clusterPath, "\n",
    "- Cluster:", clusterSubset, "\n",
    "- Imagery year:", year, "\n",
    "- Ortho tile index gpkg:", orthoIndex, "\n",
    "- HUC DEM directory:", demDir, "\n",
    "- Output path:", outputPath, "\n",
    "- Target HUC12 (blank = all in cluster):", targetHuc, "\n"
)

###############################################################################################

library(terra)
library(sf)
suppressPackageStartupMessages(library(tidyverse))
suppressPackageStartupMessages(library(tidyterra))
library(future)
library(future.apply)

terraOptions(tempdir = "/ibstorage/anthony/NYS_Wetlands_Data/Data/tmp")
print(tempdir())
setGDALconfig("GDAL_PAM_ENABLED", "FALSE") # does not create aux.xml files
dir.create(outputPath, recursive = TRUE, showWarnings = FALSE)
###############################################################################################

# Footprint index of all downloaded ortho tiles (built by gdaltindex_ortho.sh).
# `location` is a path like "Tiles/c_..._<year>.tif" relative to Data/Ortho/.
ortho_index <- st_read(orthoIndex, quiet = TRUE) |>
    st_transform(st_crs("EPSG:6347"))

# Keep only tiles for the requested year so we never mosaic mixed-year imagery
# (the year is the trailing token of the tile filename, e.g. ..._4bd_2023.tif).
ortho_index <- ortho_index[grepl(paste0("_", year, "\\.tif$"), ortho_index$location), ]
message("Ortho tiles in index for year ", year, ": ", nrow(ortho_index))
if (nrow(ortho_index) == 0) {
    stop("No ortho tiles found in the index for year ", year,
         ". Did Ortho_ftp.R run and was gdaltindex_ortho.sh re-run afterwards?")
}

# Cluster of HUCs
cluster_target <- sf::st_read(clusterPath, quiet = TRUE) |>
    dplyr::filter(cluster == clusterSubset)
cluster_hucs <- cluster_target[["huc12"]]

# Optional: restrict to a single target HUC12
if (nzchar(targetHuc)) {
    cluster_hucs <- cluster_hucs[cluster_hucs == targetHuc]
    if (length(cluster_hucs) == 0) {
        stop("Target HUC12 ", targetHuc, " not found in cluster ", clusterSubset)
    }
}

# Restrict the index to tiles intersecting this cluster (cheap pre-filter).
ortho_int_cluster <- st_filter(ortho_index, cluster_target, .predicate = st_intersects)
message("Ortho tiles overlapping cluster ", clusterSubset, ": ", nrow(ortho_int_cluster))

###############################################################################################

process_huc <- function(huc_num) {
    setGDALconfig("GDAL_PAM_ENABLED", "FALSE")
    terra::terraOptions(
        tempdir = "/ibstorage/anthony/NYS_Wetlands_Data/Data/tmp",
        memmax = 28
    )
    target_file  <- paste0(outputPath, "cluster_", clusterSubset, "_huc_", huc_num, "_ortho_", year, ".tif")
    dem_filename <- paste0(demDir, "/cluster_", clusterSubset, "_huc_", huc_num, ".tif")
    huc <- cluster_target[cluster_target$huc12 == huc_num, ]

    if (file.exists(target_file)) {
        message("Ortho already processed for: ", target_file)
        return(NULL)
    }
    # The DEM is the alignment template; without it we cannot match the stack grid.
    if (!file.exists(dem_filename)) {
        warning("No DEM for HUC ", huc_num, " at ", dem_filename, " -- skipping (cannot align).")
        return(NULL)
    }

    ortho_tiles_huc <- st_filter(ortho_int_cluster, huc, .predicate = st_intersects)
    if (nrow(ortho_tiles_huc) == 0) {
        warning("No ortho tiles overlap HUC ", huc_num, " -- skipping.")
        return(NULL)
    }
    message("Processing ", target_file, " from ", nrow(ortho_tiles_huc), " tile(s)")

    # Resolve tile paths relative to Data/Ortho/ (index `location` is relative).
    locs <- ortho_tiles_huc$location
    locs <- ifelse(file.exists(locs), locs, file.path("Data/Ortho", locs))

    huc_vect <- vect(huc)
    # Tiles are already EPSG:6347 / 1 m, so mosaic -> crop/mask -> resample onto
    # the HUC12's DEM grid (the final resample is what guarantees pixel-for-pixel
    # alignment with the DEM/LiDAR stack regardless of any origin offset).
    o <- terra::sprc(locs) |>
        terra::mosaic(fun = "first") |>
        terra::crop(huc_vect, mask = TRUE) |>
        terra::resample(y = rast(dem_filename), method = "bilinear")
    set.names(o, c("r", "g", "b", "nir"))

    writeRaster(o, filename = target_file, overwrite = TRUE)
    rm(o)
    gc()
    return(NULL)
}

###############################################################################################

slurm_cpus <- Sys.getenv("SLURM_CPUS_PER_TASK", unset = "")

if (nzchar(slurm_cpus)) {
  corenum <- as.integer(slurm_cpus)
} else {
  corenum <- min(future::availableCores(), 4)
}
options(future.globals.maxSize = 64 * 1e9)
plan(future.callr::callr, workers = corenum)

future_lapply(
    cluster_hucs,
    FUN = process_huc,
    future.packages = c("terra", "sf", "dplyr"),
    future.seed = TRUE,
    future.globals = TRUE
)

gc()

# Non-parallel fallback:
# lapply(cluster_hucs, FUN = process_huc)
