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

# Tag each tile with its imagery year (trailing token of the filename, e.g.
# ..._4bd_2023.tif) and drop any non-conforming names. We do NOT hard-filter to
# one year: a HUC12 on a collection boundary may need a second year to fill the
# part the preferred year doesn't cover (see select_tiles_for_huc).
ortho_index$tile_year <- sub(".*_(\\d{4})\\.tif$", "\\1", ortho_index$location)
ortho_index <- ortho_index[grepl("_\\d{4}\\.tif$", ortho_index$location), ]
years_available <- sort(unique(ortho_index$tile_year))
message("Ortho tile years available in index: ", paste(years_available, collapse = ", "))
if (!year %in% years_available) {
    stop("Preferred year ", year, " has no tiles in the index (have: ",
         paste(years_available, collapse = ", "),
         "). Did Ortho_ftp.R run for that year and was gdaltindex_ortho.sh re-run afterwards?")
}

# Fraction of a HUC's area allowed to remain uncovered before we treat the
# current year as "not fully covering" and pull in another year to fill it.
# Guards against sliver/float artifacts from the polygon difference.
GAP_TOL <- 0.001  # 0.1% of HUC area

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

# Choose which tiles cover a HUC12, preferring a single (homogeneous) year.
# Strategy: take the preferred year's tiles first; if they leave more than
# GAP_TOL of the HUC uncovered, fill the remaining gap with the nearest-in-time
# year(s), each restricted to tiles that actually touch the gap. Returns the
# tile paths in mosaic order (preferred first, so fun="first" keeps the
# preferred year wherever it exists) plus the ordered list of years used.
select_tiles_for_huc <- function(tiles_huc, huc_geom, preferred_year, years_available) {
    huc_geom <- sf::st_make_valid(huc_geom)
    huc_area <- as.numeric(sf::st_area(huc_geom))

    # Year search order: preferred first, then nearest-in-time (newer breaks ties).
    others <- setdiff(years_available, preferred_year)
    others <- others[order(abs(as.integer(others) - as.integer(preferred_year)),
                           -as.integer(others))]
    year_order <- c(preferred_year, others)

    selected   <- tiles_huc[0, ]   # empty, same columns -> preserves mosaic order
    used_years <- character(0)
    covered    <- NULL
    for (yr in year_order) {
        gap <- if (is.null(covered)) huc_geom else sf::st_difference(huc_geom, covered)
        gap <- sf::st_make_valid(gap)
        gap_area <- if (length(gap) == 0) 0 else sum(as.numeric(sf::st_area(gap)))
        if (gap_area / huc_area < GAP_TOL) break          # HUC effectively covered

        yr_tiles <- tiles_huc[tiles_huc$tile_year == yr, ]
        if (nrow(yr_tiles) == 0) next
        yr_tiles <- yr_tiles[lengths(sf::st_intersects(yr_tiles, gap)) > 0, ]  # only those touching the gap
        if (nrow(yr_tiles) == 0) next

        selected   <- rbind(selected, yr_tiles)
        used_years <- c(used_years, yr)
        yr_union   <- sf::st_union(sf::st_geometry(yr_tiles))
        covered    <- if (is.null(covered)) yr_union else sf::st_union(covered, yr_union)
    }
    list(locs = selected$location, years = used_years)
}

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

    # Prefer the requested year; fill any uncovered gap with the nearest year(s).
    sel <- select_tiles_for_huc(ortho_tiles_huc, st_geometry(huc), year, years_available)
    if (length(sel$locs) == 0) {
        warning("No tiles selected for HUC ", huc_num, " -- skipping.")
        return(NULL)
    }
    homog <- if (length(sel$years) <= 1) "homogeneous" else "MIXED"
    message("Processing ", target_file, " from ", length(sel$locs),
            " tile(s); years used: ", paste(sel$years, collapse = "+"), " (", homog, ")")

    # Resolve tile paths relative to Data/Ortho/ (index `location` is relative).
    locs <- ifelse(file.exists(sel$locs), sel$locs, file.path("Data/Ortho", sel$locs))

    # Each tile carries a 0-valued collar from the -tap grid-snap at download
    # time. Under mosaic(fun="first") that collar would overwrite a neighbour's
    # real pixels and draw black seams along the tile grid. Flag the collar as NA
    # so neighbours fill it -- but ONLY where all four bands are 0 (true collar),
    # so a legit single-band zero such as NIR~0 over water is preserved.
    tiles <- lapply(locs, function(f) {
        r <- terra::rast(f)
        collar <- (r[[1]] == 0) & (r[[2]] == 0) & (r[[3]] == 0) & (r[[4]] == 0)
        r[collar] <- NA
        r
    })

    huc_vect <- vect(huc)
    # Tiles are already EPSG:6347 / 1 m, so mosaic -> crop/mask -> resample onto
    # the HUC12's DEM grid (the final resample is what guarantees pixel-for-pixel
    # alignment with the DEM/LiDAR stack regardless of any origin offset). tiles is
    # ordered preferred-year-first, so fun="first" keeps the preferred year
    # wherever it has coverage and only fills gaps with the later years.
    o <- terra::sprc(tiles) |>
        terra::mosaic(fun = "first")
    # Close any hairline NA seam left where tiles only abut (both collars NA at
    # the shared edge). na.policy="only" fills NA cells from their neighbours and
    # leaves real pixels untouched; done BEFORE crop so it can't bleed past the
    # HUC boundary. Same gap-fill idiom as the DEM extraction step.
    o <- terra::focal(o, w = 3, fun = "mean", na.policy = "only", na.rm = TRUE)
    o <- terra::crop(o, huc_vect, mask = TRUE) |>
        terra::resample(y = rast(dem_filename), method = "bilinear")
    set.names(o, c("r", "g", "b", "nir"))
    # Record imagery provenance in the GeoTIFF metadata (no sidecar needed).
    terra::metags(o) <- c(ortho_years = paste(sel$years, collapse = ","),
                          ortho_preferred_year = as.character(year))

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
